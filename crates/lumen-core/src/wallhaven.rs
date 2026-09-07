//! Reading a Wallhaven id back out of a filename.
//!
//! Wallhaven names its downloads after the wallpaper, so a folder collected
//! from the site years ago can be matched back to it without any record of
//! where the files came from. That is what lets the app say "you already have
//! this" while browsing, and what lets the CLI refill metadata that was never
//! written to disk.
//!
//! Shared because three places must agree on it: the metadata backfill, the
//! library index, and the Swift side that mirrors this exactly.

/// The id a filename carries, if it carries one.
///
/// Both forms Wallhaven has used are accepted: `wallhaven-<id>.jpg`, which the
/// site serves today, and a bare `<id>.jpg`, which it used to.
///
/// Six characters of lowercase letters and digits is the whole test. It is
/// deliberately strict — a looser rule would read `sunset.jpg` as an id and
/// spend a request finding out it is not one.
pub fn id_from_filename(name: &str) -> Option<String> {
    let stem = std::path::Path::new(name).file_stem()?.to_str()?;
    let stem = stem.strip_prefix("wallhaven-").unwrap_or(stem);
    if stem.len() == 6 && stem.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) {
        Some(stem.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_naming_conventions_are_recognised() {
        assert_eq!(id_from_filename("wallhaven-395yv3.jpg").as_deref(), Some("395yv3"));
        assert_eq!(id_from_filename("47m1xy.jpeg").as_deref(), Some("47m1xy"));
        assert_eq!(id_from_filename("xe9zld.png").as_deref(), Some("xe9zld"));
    }

    #[test]
    fn anything_of_another_shape_is_not_an_id() {
        assert_eq!(id_from_filename("my wallpaper.jpg"), None);
        assert_eq!(id_from_filename("IMG_4021.jpeg"), None);
        assert_eq!(id_from_filename("photo-2019.png"), None);
        assert_eq!(id_from_filename("ab12.jpg"), None);
        // Uppercase is not a Wallhaven id.
        assert_eq!(id_from_filename("XE9ZLD.jpg"), None);
    }

    #[test]
    fn a_six_letter_word_is_indistinguishable_and_that_is_accepted() {
        // The cost of this is one wasted lookup, not a wrong write.
        assert_eq!(id_from_filename("sunset.jpg").as_deref(), Some("sunset"));
    }
}
