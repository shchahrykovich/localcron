//! Who is on the other end of a socket connection. Only the menu bar app may
//! allow a job to read its secrets, and only after the user confirms there:
//! anything else that reaches the socket (an agent, the CLI, a script) could
//! otherwise write a job that prints a secret and allow it too.
//!
//! The peer is found by its audit token, which the kernel gives and the peer
//! cannot fake, and checked against a code requirement:
//! - Developer ID builds: the app's identifier, signed by the daemon's own
//!   team (read from the daemon's signature).
//! - Ad-hoc builds: the app's identifier, and the app program of the bundle
//!   the daemon runs from. Weaker: anything running as the user can replace
//!   a bundle in ~/Applications. Good enough for a dev build.
//! - No bundle (`cargo run`, tests): nobody. Debug builds accept every peer
//!   when `LOCALCRON_TEST_TRUST_PEERS=1`.

use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use core_foundation::base::TCFType;
use core_foundation::data::CFData;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::CFString;
use core_foundation_sys::dictionary::CFDictionaryRef;
use core_foundation_sys::string::CFStringRef;
use security_framework::os::macos::code_signing::{Flags, GuestAttributes, SecCode, SecRequirement};

use localcron_core::instance::Instance;

/// What a connection may do beyond the plain API.
pub struct Trust {
    /// The peer is this instance's menu bar app.
    pub app: bool,
}

/// How the daemon recognizes its app. Made once at start.
pub struct AppCheck {
    requirement: Option<String>,
    /// Ad-hoc builds: the app program in the daemon's own bundle.
    app_program: Option<PathBuf>,
    trust_all: bool,
}

impl AppCheck {
    pub fn for_this_daemon(instance: &Instance) -> Self {
        let trust_all = cfg!(debug_assertions) && std::env::var_os("LOCALCRON_TEST_TRUST_PEERS").is_some_and(|v| v == "1");
        let exe = std::env::current_exe().ok().and_then(|p| p.canonicalize().ok());
        let app_program = exe.as_deref().and_then(app_program_next_to);
        let id = instance.bundle_id();
        let requirement = match (own_team(), &app_program) {
            (Some(team), _) => {
                Some(format!("identifier \"{id}\" and anchor apple generic and certificate leaf[subject.OU] = \"{team}\""))
            }
            (None, Some(_)) => Some(format!("identifier \"{id}\"")),
            (None, None) => None,
        };
        Self { requirement, app_program, trust_all }
    }

    pub fn trust(&self, stream: &UnixStream) -> Trust {
        Trust { app: self.trust_all || self.is_app(stream) }
    }

    fn is_app(&self, stream: &UnixStream) -> bool {
        let Some(text) = &self.requirement else { return false };
        let Some(token) = peer_audit_token(stream) else { return false };
        let mut attrs = GuestAttributes::new();
        let data = CFData::from_buffer(&token);
        attrs.set_audit_token(data.as_concrete_TypeRef());
        let Ok(code) = SecCode::copy_guest_with_attribues(None, &attrs, Flags::NONE) else { return false };
        let Ok(requirement) = SecRequirement::from_str(text) else { return false };
        if code.check_validity(Flags::NONE, &requirement).is_err() {
            return false;
        }
        match &self.app_program {
            // Developer ID: the team says enough. Ad-hoc: also the place.
            Some(program) if own_team().is_none() => code_path(&code).is_some_and(|p| &p == program),
            _ => true,
        }
    }
}

/// `…/LocalCron.app/Contents/MacOS/localcrond` → `…/LocalCron.app/Contents/MacOS/LocalCron`.
fn app_program_next_to(daemon: &Path) -> Option<PathBuf> {
    let macos = daemon.parent()?;
    let contents = macos.parent()?;
    let bundle = contents.parent()?;
    (macos.file_name()? == "MacOS" && contents.file_name()? == "Contents" && bundle.extension()? == "app")
        .then(|| macos.join("LocalCron"))
}

fn code_path(code: &SecCode) -> Option<PathBuf> {
    let url = code.path(Flags::NONE).ok()?;
    let path = url.to_path()?;
    // A bundle's path is the bundle; its program is inside.
    let program = if path.extension().is_some_and(|e| e == "app") { path.join("Contents/MacOS/LocalCron") } else { path };
    program.canonicalize().ok()
}

fn peer_audit_token(stream: &UnixStream) -> Option<[u8; 32]> {
    let mut token = [0u8; 32];
    let mut len = token.len() as libc::socklen_t;
    // SAFETY: getsockopt writes at most `len` bytes into `token`.
    let rc = unsafe {
        libc::getsockopt(stream.as_raw_fd(), libc::SOL_LOCAL, libc::LOCAL_PEERTOKEN, token.as_mut_ptr().cast(), &mut len)
    };
    (rc == 0 && len as usize == token.len()).then_some(token)
}

const SIGNING_INFORMATION: u32 = 1 << 1;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecCodeInfoTeamIdentifier: CFStringRef;
    fn SecCodeCopySigningInformation(code: *const libc::c_void, flags: u32, information: *mut CFDictionaryRef) -> i32;
}

/// The team that signed this program; None for ad-hoc and unsigned builds.
fn own_team() -> Option<String> {
    let me = SecCode::for_self(Flags::NONE).ok()?;
    let mut info: CFDictionaryRef = std::ptr::null();
    // SAFETY: a valid code object; on success `info` is a dictionary we own.
    let rc = unsafe { SecCodeCopySigningInformation(me.as_CFTypeRef(), SIGNING_INFORMATION, &mut info) };
    if rc != 0 || info.is_null() {
        return None;
    }
    // SAFETY: created by the call above.
    let info: CFDictionary<CFString, core_foundation::base::CFType> = unsafe { CFDictionary::wrap_under_create_rule(info) };
    // SAFETY: a constant of the Security framework.
    let key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoTeamIdentifier) };
    let team = info.find(&key)?.downcast::<CFString>()?.to_string();
    (!team.is_empty()).then_some(team)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_app_program_is_found_only_inside_a_bundle() {
        assert_eq!(
            app_program_next_to(Path::new("/Applications/LocalCron-dev.app/Contents/MacOS/localcrond-dev")),
            Some(PathBuf::from("/Applications/LocalCron-dev.app/Contents/MacOS/LocalCron"))
        );
        assert_eq!(app_program_next_to(Path::new("/Users/me/localcron/target/debug/localcrond")), None);
    }

    #[test]
    fn a_test_program_is_not_the_app() {
        let check = AppCheck::for_this_daemon(&Instance::release());
        // A test binary has no team and no bundle: nobody is the app.
        assert!(check.requirement.is_none());
        let (a, _b) = UnixStream::pair().unwrap();
        assert!(peer_audit_token(&a).is_some(), "the kernel gives the peer's audit token");
        assert!(!check.is_app(&a));
    }
}
