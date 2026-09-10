
// Run each environment case in its own process. Mutating the test runner's environment would race with other shell detection tests.
#[cfg(all(test, unix))]
mod process_shell_tests {
    use super::*;
    use std::ffi::OsStr;
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;
    use std::process::Command;

    fn run_probe(case: &str, shell: Option<&OsStr>) {
        let mut child = Command::new(std::env::current_exe().expect("test executable"));
        child
            .args([
                "--exact",
                "shell_detect::process_shell_tests::shell_probe",
                "--nocapture",
            ])
            .env("CODEX_FLAKE_SHELL_CASE", case)
            .env_remove("SHELL");
        if let Some(shell) = shell {
            child.env("SHELL", shell);
        }
        let output = child.output().expect("run isolated shell probe");
        assert!(
            output.status.success(),
            "shell probe {case} failed:\n{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("running 1 test"),
            "isolated shell probe did not run: {}",
            String::from_utf8_lossy(&output.stdout),
        );
    }

    #[test]
    fn prefers_process_shell_for_default_shell() {
        let directory = tempfile::tempdir().expect("temporary shell directory");
        let shell = directory.path().join("bash");
        std::fs::write(&shell, "").expect("shell file");
        run_probe("preferred", Some(shell.as_os_str()));
    }

    #[test]
    fn empty_process_shell_uses_passwd() {
        run_probe("fallback", Some(OsStr::new("")));
    }

    #[test]
    fn unset_process_shell_uses_passwd() {
        run_probe("fallback", None);
    }

    #[test]
    fn process_shell_preserves_non_utf8_paths() {
        let shell = OsString::from_vec(b"/codex-flake-shell-\xff/bash".to_vec());
        run_probe("non-utf8", Some(&shell));
    }

    fn passwd_shell() -> Option<PathBuf> {
        let mut passwd = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut result = std::ptr::null_mut();
        let mut buffer = vec![0u8; 1024 * 1024];
        let status = unsafe {
            libc::getpwuid_r(
                libc::getuid(),
                passwd.as_mut_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        assert_eq!(status, 0, "read passwd entry for fallback expectation");
        if result.is_null() {
            return None;
        }
        let passwd = unsafe { passwd.assume_init_ref() };
        if passwd.pw_shell.is_null() {
            return None;
        }
        Some(PathBuf::from(
            unsafe { std::ffi::CStr::from_ptr(passwd.pw_shell) }
                .to_string_lossy()
                .into_owned(),
        ))
    }

    #[test]
    fn shell_probe() {
        let Ok(case) = std::env::var("CODEX_FLAKE_SHELL_CASE") else {
            return;
        };
        match case.as_str() {
            "preferred" => {
                let expected = PathBuf::from(std::env::var_os("SHELL").expect("child SHELL"));
                assert_eq!(get_user_shell_path(), Some(expected.clone()));
                assert_eq!(default_user_shell().shell_path, expected);
                assert_eq!(default_user_shell().shell_type, ShellType::Bash);
            }
            "non-utf8" => assert_eq!(
                get_user_shell_path(),
                std::env::var_os("SHELL").map(PathBuf::from),
            ),
            "fallback" => assert_eq!(get_user_shell_path(), passwd_shell()),
            other => panic!("unknown shell probe case: {other}"),
        }
    }
}
