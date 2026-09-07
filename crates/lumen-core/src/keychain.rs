//! The Wallhaven API key, in the login keychain.
//!
//! One item, shared by the app and the CLI. It used to sit in the app's
//! `UserDefaults` — a plain file under `~/Library/Preferences` readable by
//! anything running as the user — and then, briefly, in the database as well.
//! A key is a credential, so it belongs behind the same door as a password.
//!
//! The Swift side writes the identical item through `SecItem`; these constants
//! are the contract between the two.

/// Keychain service and account. Must match `Keychain.swift`.
pub const SERVICE: &str = "cc.lumen.app";
pub const ACCOUNT: &str = "wallhaven-api-key";

/// The stored key, or `None` when there is none.
///
/// Every failure means the same thing to a caller — carry on unauthenticated —
/// so a locked keychain and a missing item are not distinguished. A binary that
/// is not the app will be prompted for access the first time; declining is a
/// legitimate answer, not an error to report.
#[cfg(target_os = "macos")]
pub fn api_key() -> Option<String> {
    let bytes = security_framework::passwords::get_generic_password(SERVICE, ACCOUNT).ok()?;
    let key = String::from_utf8(bytes).ok()?;
    let trimmed = key.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// Stores `key`, replacing whatever was there. An empty key removes the item.
#[cfg(target_os = "macos")]
pub fn set_api_key(key: &str) -> crate::Result<()> {
    let trimmed = key.trim();
    if trimmed.is_empty() {
        return remove_api_key();
    }
    security_framework::passwords::set_generic_password(SERVICE, ACCOUNT, trimmed.as_bytes())
        .map_err(|e| crate::LumenError::Other(format!("keychain: {e}")))
}

#[cfg(target_os = "macos")]
pub fn remove_api_key() -> crate::Result<()> {
    match security_framework::passwords::delete_generic_password(SERVICE, ACCOUNT) {
        Ok(()) => Ok(()),
        // Removing a key that is not there is the outcome the caller wanted.
        Err(e) if e.code() == -25300 => Ok(()),
        Err(e) => Err(crate::LumenError::Other(format!("keychain: {e}"))),
    }
}

#[cfg(not(target_os = "macos"))]
pub fn api_key() -> Option<String> {
    None
}

#[cfg(not(target_os = "macos"))]
pub fn set_api_key(_key: &str) -> crate::Result<()> {
    Err(crate::LumenError::Other("no keychain on this platform".into()))
}

#[cfg(not(target_os = "macos"))]
pub fn remove_api_key() -> crate::Result<()> {
    Ok(())
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    /// The constants are a contract with `Keychain.swift`; changing one without
    /// the other silently separates the app's key from the CLI's.
    #[test]
    fn the_item_is_named_the_same_as_the_swift_side() {
        let swift = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../apps/Lumen/Sources/Model/Keychain.swift"
        ));
        let Ok(swift) = swift else { return };
        assert!(swift.contains(&format!("service = \"{SERVICE}\"")), "service drifted");
        assert!(swift.contains(&format!("account = \"{ACCOUNT}\"")), "account drifted");
    }
}
