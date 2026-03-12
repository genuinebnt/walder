use iced::widget::{button, container, scrollable, text_input};
use iced::{Background, Border, Color, Shadow, Theme as IcedTheme, Vector, border, theme::Palette};

use wallsetter_core::Theme;

pub fn active_theme(theme: Theme) -> IcedTheme {
    match theme {
        Theme::Light => codex_light(),
        Theme::Dark => codex_dark(),
    }
}

fn codex_dark() -> IcedTheme {
    IcedTheme::custom(
        "Walder Dark".to_string(),
        Palette {
            background: Color::from_rgb8(0x1C, 0x1C, 0x1E),
            text: Color::from_rgb8(0xF2, 0xF2, 0xF7),
            primary: Color::from_rgb8(0x0A, 0x84, 0xFF),
            success: Color::from_rgb8(0x30, 0xD1, 0x58),
            danger: Color::from_rgb8(0xFF, 0x45, 0x3A),
        },
    )
}

fn codex_light() -> IcedTheme {
    IcedTheme::custom(
        "Walder Light".to_string(),
        Palette {
            background: Color::from_rgb8(0xF2, 0xF2, 0xF7),
            text: Color::from_rgb8(0x1C, 0x1C, 0x1E),
            primary: Color::from_rgb8(0x00, 0x7A, 0xFF),
            success: Color::from_rgb8(0x34, 0xC7, 0x59),
            danger: Color::from_rgb8(0xFF, 0x3B, 0x30),
        },
    )
}

// ── Containers ─────────────────────────────────────────────────────────────

/// Top toolbar bar
pub fn toolbar(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.background.weak.color.scale_alpha(0.92))
        .border(Border {
            color: palette.background.strong.color.scale_alpha(0.25),
            width: 1.0,
            ..border::rounded(0)
        })
        .shadow(Shadow {
            color: Color::BLACK.scale_alpha(0.08),
            offset: Vector::new(0.0, 1.0),
            blur_radius: 6.0,
        })
}

/// Elevated surface — card or side panel
pub fn panel(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.background.weak.color.scale_alpha(0.80))
        .border(Border {
            color: palette.background.strong.color.scale_alpha(0.30),
            width: 1.0,
            ..border::rounded(12)
        })
        .shadow(Shadow {
            color: Color::BLACK.scale_alpha(0.08),
            offset: Vector::new(0.0, 1.0),
            blur_radius: 6.0,
        })
}

/// Lower-contrast inset surface
pub fn panel_subtle(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.background.weak.color.scale_alpha(0.45))
        .border(Border {
            color: palette.background.strong.color.scale_alpha(0.22),
            width: 1.0,
            ..border::rounded(10)
        })
}

pub fn app_frame(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.background.base.color)
        .border(Border {
            color: palette.background.strong.color.scale_alpha(0.20),
            width: 1.0,
            ..border::rounded(12)
        })
}

pub fn panel_nsfw(_theme: &IcedTheme) -> container::Style {
    container::Style::default()
        .background(Color::from_rgba8(0x2C, 0x00, 0x00, 0.50))
        .border(Border {
            color: Color::from_rgb8(0xFF, 0x45, 0x3A),
            width: 2.0,
            ..border::rounded(10)
        })
}

pub fn panel_sketchy(_theme: &IcedTheme) -> container::Style {
    container::Style::default()
        .background(Color::from_rgba8(0x2C, 0x20, 0x00, 0.50))
        .border(Border {
            color: Color::from_rgb8(0xFF, 0x9F, 0x0A),
            width: 2.0,
            ..border::rounded(10)
        })
}

pub fn panel_selected(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.primary.weak.color.scale_alpha(0.28))
        .border(Border {
            color: palette.primary.base.color,
            width: 2.0,
            ..border::rounded(10)
        })
        .shadow(Shadow {
            color: palette.primary.base.color.scale_alpha(0.18),
            offset: Vector::new(0.0, 2.0),
            blur_radius: 8.0,
        })
}

// ── Chips ───────────────────────────────────────────────────────────────────

pub fn chip_neutral(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.background.strong.color.scale_alpha(0.28))
        .color(palette.background.base.text)
        .border(border::rounded(999))
}

pub fn chip_info(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.primary.weak.color.scale_alpha(0.36))
        .color(palette.primary.base.text)
        .border(border::rounded(999))
}

pub fn chip_success(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.success.weak.color.scale_alpha(0.36))
        .color(palette.success.base.text)
        .border(border::rounded(999))
}

pub fn chip_danger(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();
    container::Style::default()
        .background(palette.danger.weak.color.scale_alpha(0.36))
        .color(palette.danger.base.text)
        .border(border::rounded(999))
}

// ── Buttons ─────────────────────────────────────────────────────────────────

/// Filled accent button (primary action)
pub fn button_primary(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: Some(Background::Color(palette.primary.base.color)),
        text_color: palette.primary.base.text,
        border: Border {
            color: Color::TRANSPARENT,
            width: 0.0,
            ..border::rounded(8)
        },
        shadow: Shadow {
            color: palette.primary.base.color.scale_alpha(0.30),
            offset: Vector::new(0.0, 1.0),
            blur_radius: 5.0,
        },
    };

    match status {
        button::Status::Active => base,
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(palette.primary.strong.color)),
            ..base
        },
        button::Status::Pressed => button::Style {
            shadow: Shadow::default(),
            background: Some(Background::Color(palette.primary.strong.color)),
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.40),
            background: base.background.map(|bg| match bg {
                Background::Color(c) => Background::Color(c.scale_alpha(0.45)),
                _ => bg,
            }),
            shadow: Shadow::default(),
            ..base
        },
    }
}

/// Secondary / outlined button
pub fn button_secondary(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: Some(Background::Color(
            palette.background.weak.color.scale_alpha(0.80),
        )),
        text_color: palette.background.base.text,
        border: Border {
            color: palette.background.strong.color.scale_alpha(0.40),
            width: 1.0,
            ..border::rounded(8)
        },
        shadow: Shadow::default(),
    };

    match status {
        button::Status::Active => base,
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.28),
            )),
            ..base
        },
        button::Status::Pressed => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.38),
            )),
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.40),
            ..base
        },
    }
}

/// Destructive action button
pub fn button_danger(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: Some(Background::Color(palette.danger.base.color)),
        text_color: palette.danger.base.text,
        border: Border {
            color: Color::TRANSPARENT,
            width: 0.0,
            ..border::rounded(8)
        },
        shadow: Shadow::default(),
    };

    match status {
        button::Status::Active => base,
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(palette.danger.strong.color)),
            ..base
        },
        button::Status::Pressed => button::Style {
            shadow: Shadow::default(),
            background: Some(Background::Color(palette.danger.strong.color)),
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.40),
            ..base
        },
    }
}

/// Ghost / icon-only navigation button (no border when inactive)
pub fn button_ghost(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: None,
        text_color: palette.background.base.text.scale_alpha(0.75),
        border: Border {
            color: Color::TRANSPARENT,
            width: 0.0,
            ..border::rounded(8)
        },
        shadow: Shadow::default(),
    };

    match status {
        button::Status::Active => base,
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.22),
            )),
            text_color: palette.background.base.text,
            ..base
        },
        button::Status::Pressed => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.30),
            )),
            text_color: palette.background.base.text,
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.30),
            ..base
        },
    }
}

/// Active tab in the segment control
pub fn tab_active(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: Some(Background::Color(palette.background.base.color)),
        text_color: palette.primary.base.color,
        border: Border {
            color: palette.background.strong.color.scale_alpha(0.25),
            width: 1.0,
            ..border::rounded(7)
        },
        shadow: Shadow {
            color: Color::BLACK.scale_alpha(0.10),
            offset: Vector::new(0.0, 1.0),
            blur_radius: 4.0,
        },
    };

    match status {
        button::Status::Active | button::Status::Hovered | button::Status::Pressed => base,
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.40),
            ..base
        },
    }
}

/// Inactive tab in the segment control
pub fn tab_inactive(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: None,
        text_color: palette.background.base.text.scale_alpha(0.65),
        border: Border {
            color: Color::TRANSPARENT,
            width: 1.0,
            ..border::rounded(7)
        },
        shadow: Shadow::default(),
    };

    match status {
        button::Status::Active => base,
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.18),
            )),
            text_color: palette.background.base.text,
            ..base
        },
        button::Status::Pressed => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.25),
            )),
            text_color: palette.background.base.text,
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.30),
            ..base
        },
    }
}

#[allow(dead_code)]
pub fn button_flat(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: None,
        text_color: palette.background.base.text,
        border: Border {
            color: Color::TRANSPARENT,
            width: 1.0,
            ..border::rounded(8)
        },
        shadow: Shadow::default(),
    };

    match status {
        button::Status::Active => base,
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.22),
            )),
            border: Border {
                color: palette.background.strong.color.scale_alpha(0.38),
                ..base.border
            },
            ..base
        },
        button::Status::Pressed => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.30),
            )),
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.40),
            ..base
        },
    }
}

// ── Text input ───────────────────────────────────────────────────────────────

pub fn text_input_style(theme: &IcedTheme, status: text_input::Status) -> text_input::Style {
    let palette = theme.extended_palette();
    let base = text_input::Style {
        background: Background::Color(palette.background.weak.color.scale_alpha(0.65)),
        border: Border {
            color: palette.background.strong.color.scale_alpha(0.45),
            width: 1.0,
            ..border::rounded(8)
        },
        icon: palette.background.strong.text,
        placeholder: palette.background.strong.color,
        value: palette.background.base.text,
        selection: palette.primary.weak.color,
    };

    match status {
        text_input::Status::Active => base,
        text_input::Status::Hovered => text_input::Style {
            border: Border {
                color: palette.primary.weak.color.scale_alpha(0.55),
                ..base.border
            },
            ..base
        },
        text_input::Status::Focused => text_input::Style {
            background: Background::Color(palette.background.base.color),
            border: Border {
                color: palette.primary.base.color,
                width: 1.5,
                ..base.border
            },
            ..base
        },
        text_input::Status::Disabled => text_input::Style {
            value: base.value.scale_alpha(0.40),
            background: Background::Color(palette.background.weak.color.scale_alpha(0.35)),
            ..base
        },
    }
}

// ── Scrollbar ────────────────────────────────────────────────────────────────

/// Thin macOS-style overlay scrollbar
pub fn scrollbar(theme: &IcedTheme, status: scrollable::Status) -> scrollable::Style {
    let palette = theme.extended_palette();

    let is_active = matches!(
        status,
        scrollable::Status::Hovered { .. }
            | scrollable::Status::Dragged { .. }
    );

    let scroller_alpha = if is_active { 0.55 } else { 0.25 };
    let rail_alpha = if is_active { 0.08 } else { 0.0 };

    let rail = scrollable::Rail {
        background: Some(Background::Color(
            palette.background.strong.color.scale_alpha(rail_alpha),
        )),
        border: border::rounded(4),
        scroller: scrollable::Scroller {
            color: palette.background.base.text.scale_alpha(scroller_alpha),
            border: border::rounded(4),
        },
    };

    scrollable::Style {
        container: container::Style::default(),
        vertical_rail: rail,
        horizontal_rail: rail,
        gap: None,
    }
}
