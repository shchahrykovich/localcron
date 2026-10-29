//! Secret values in the macOS Keychain: one generic password per secret,
//! service `dev.localcron.app.secrets` (with the instance suffix), account
//! the secret's name.
//!
//! The daemon is a LaunchAgent in the user's login session, and macOS unlocks
//! the login keychain at login, so a run at night reads its secrets with
//! nobody there. The program that adds an item may read it later without a
//! dialog; that is why only the daemon writes items, never the CLI or the app.
//!
//! The daemon never shows a dialog: nobody may be there to answer it, and it
//! would hold the run. User interaction is turned off for the whole process,
//! so a read that needs one fails at once with `errSecInteractionNotAllowed`
//! (the keychain is locked, or another build of the daemon made the item: an
//! ad-hoc signed build after a rebuild).

use std::path::PathBuf;
use std::sync::Once;

use security_framework::base::Error;
use security_framework::os::macos::keychain::{CreateOptions, SecKeychain};
use security_framework::os::macos::passwords::find_generic_password;

use localcron_core::instance::Instance;

const ITEM_NOT_FOUND: i32 = -25300;
const INTERACTION_NOT_ALLOWED: i32 = -25308;
/// What a read gets when another build of the daemon stored the item and the
/// Keychain may not ask the user.
const AUTH_FAILED: i32 = -25293;
#[cfg(any(test, debug_assertions))]
const TEST_PASSWORD: &str = "localcron-test";

#[derive(Debug, PartialEq, Eq)]
pub enum ReadError {
    Missing,
    /// Why, for the run's message.
    Unreadable(String),
}

pub struct Keychain {
    service: String,
    /// A keychain file instead of the user's default keychain: tests only.
    file: Option<PathBuf>,
}

impl Keychain {
    /// Debug builds use the keychain file in `LOCALCRON_TEST_KEYCHAIN` when it
    /// is set, so tests never touch the login keychain. Release builds ignore
    /// it.
    pub fn for_instance(instance: &Instance) -> Self {
        let file = if cfg!(debug_assertions) { std::env::var_os("LOCALCRON_TEST_KEYCHAIN").map(PathBuf::from) } else { None };
        Self::new(format!("{}.secrets", instance.bundle_id()), file)
    }

    fn new(service: String, file: Option<PathBuf>) -> Self {
        static NO_DIALOGS: Once = Once::new();
        NO_DIALOGS.call_once(|| match SecKeychain::disable_user_interaction() {
            // Kept off for the life of the process.
            Ok(lock) => std::mem::forget(lock),
            Err(e) => crate::log!("cannot turn off Keychain dialogs: {e}"),
        });
        Self { service, file }
    }

    fn open(&self) -> Result<SecKeychain, Error> {
        match &self.file {
            None => SecKeychain::default(),
            Some(path) => open_test_keychain(path),
        }
    }

    pub fn set(&self, name: &str, value: &[u8]) -> Result<(), String> {
        let keychain = self.open().map_err(|e| describe(&e))?;
        match keychain.set_generic_password(&self.service, name, value) {
            Ok(()) => Ok(()),
            // An item another build made: its access list does not have this
            // program, so it cannot be changed. Replace it.
            Err(e) if e.code() == INTERACTION_NOT_ALLOWED || e.code() == AUTH_FAILED => {
                if let Ok((_, item)) = find_generic_password(Some(std::slice::from_ref(&keychain)), &self.service, name) {
                    item.delete();
                }
                keychain.add_generic_password(&self.service, name, value).map_err(|e| self.cannot_replace(name, &e))
            }
            Err(e) => Err(describe(&e)),
        }
    }

    pub fn get(&self, name: &str) -> Result<Vec<u8>, ReadError> {
        let keychain = self.open().map_err(|e| ReadError::Unreadable(describe(&e)))?;
        match find_generic_password(Some(std::slice::from_ref(&keychain)), &self.service, name) {
            Ok((password, _)) => Ok(password.to_vec()),
            Err(e) if e.code() == ITEM_NOT_FOUND => Err(ReadError::Missing),
            Err(e) => Err(ReadError::Unreadable(describe(&e))),
        }
    }

    /// False when there was no item.
    pub fn delete(&self, name: &str) -> Result<bool, String> {
        let keychain = self.open().map_err(|e| describe(&e))?;
        match find_generic_password(Some(std::slice::from_ref(&keychain)), &self.service, name) {
            Ok((_, item)) => {
                item.delete();
                Ok(true)
            }
            Err(e) if e.code() == ITEM_NOT_FOUND => Ok(false),
            Err(e) => Err(describe(&e)),
        }
    }

    fn cannot_replace(&self, name: &str, e: &Error) -> String {
        format!(
            "{}; remove the item {name} of {} in Keychain Access and set it again",
            describe(e),
            self.service
        )
    }
}

fn describe(e: &Error) -> String {
    describe_code(e.code()).unwrap_or_else(|| format!("Keychain error {}: {e}", e.code()))
}

fn describe_code(code: i32) -> Option<String> {
    match code {
        INTERACTION_NOT_ALLOWED | AUTH_FAILED => {
            Some("the Keychain needs a dialog to give the value: it is locked, or another build of LocalCron stored it".into())
        }
        _ => None,
    }
}

/// Create the file on first use, unlock it after.
#[cfg(any(test, debug_assertions))]
fn open_test_keychain(path: &std::path::Path) -> Result<SecKeychain, Error> {
    if !path.exists() {
        return CreateOptions::new().password(TEST_PASSWORD).create(path);
    }
    let mut keychain = SecKeychain::open(path)?;
    keychain.unlock(Some(TEST_PASSWORD))?;
    Ok(keychain)
}

#[cfg(not(any(test, debug_assertions)))]
fn open_test_keychain(_: &std::path::Path) -> Result<SecKeychain, Error> {
    SecKeychain::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_keychain() -> (tempfile::TempDir, Keychain) {
        let dir = tempfile::tempdir().unwrap();
        let k = Keychain::new("dev.localcron.app-test.secrets".into(), Some(dir.path().join("test.keychain")));
        (dir, k)
    }

    #[test]
    fn set_get_replace_and_delete() {
        let (_dir, k) = test_keychain();
        assert_eq!(k.get("github-token"), Err(ReadError::Missing));
        k.set("github-token", b"ghp_one").unwrap();
        assert_eq!(k.get("github-token").unwrap(), b"ghp_one");
        k.set("github-token", b"ghp_two").unwrap();
        assert_eq!(k.get("github-token").unwrap(), b"ghp_two");
        assert_eq!(k.get("other"), Err(ReadError::Missing));
        assert!(k.delete("github-token").unwrap());
        assert!(!k.delete("github-token").unwrap());
        assert_eq!(k.get("github-token"), Err(ReadError::Missing));
    }

    #[test]
    fn a_value_another_build_stored_is_explained() {
        // -25293 came from a dev build signed ad hoc, read by a Developer ID one.
        for code in [INTERACTION_NOT_ALLOWED, AUTH_FAILED] {
            assert!(describe_code(code).unwrap().contains("another build of LocalCron stored it"), "{code}");
        }
        assert_eq!(describe_code(-1), None);
    }

    #[test]
    fn items_of_another_service_are_not_seen() {
        let (dir, k) = test_keychain();
        k.set("a", b"1").unwrap();
        let other = Keychain::new("dev.localcron.app-other.secrets".into(), Some(dir.path().join("test.keychain")));
        assert_eq!(other.get("a"), Err(ReadError::Missing));
    }
}
