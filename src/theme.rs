use iced::Theme as IcedTheme;

use wallsetter_core::Theme;

pub fn active_theme(theme: Theme) -> IcedTheme {
    match theme {
        Theme::Light => IcedTheme::Light,
        Theme::Dark => IcedTheme::Dark,
    }
}

// Custom styling helpers can go here later
