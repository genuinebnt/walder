use iced::widget::{button, container, text_input};
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
        "Wallsetter Codex Dark".to_string(),
        Palette {
            background: Color::from_rgb8(0x0D, 0x11, 0x17),
            text: Color::from_rgb8(0xE6, 0xED, 0xF3),
            primary: Color::from_rgb8(0x38, 0xB3, 0xD8),
            success: Color::from_rgb8(0x2E, 0xC4, 0x8D),
            danger: Color::from_rgb8(0xF0, 0x52, 0x52),
        },
    )
}

fn codex_light() -> IcedTheme {
    IcedTheme::custom(
        "Wallsetter Codex Light".to_string(),
        Palette {
            background: Color::from_rgb8(0xF5, 0xF7, 0xFA),
            text: Color::from_rgb8(0x11, 0x18, 0x27),
            primary: Color::from_rgb8(0x0E, 0x74, 0xAF),
            success: Color::from_rgb8(0x1F, 0x9D, 0x6C),
            danger: Color::from_rgb8(0xD1, 0x43, 0x43),
        },
    )
}

pub fn app_frame(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.background.base.color)
        .border(Border {
            color: palette.background.strong.color.scale_alpha(0.30),
            width: 1.0,
            ..border::rounded(14)
        })
}

pub fn panel(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.background.weak.color.scale_alpha(0.85))
        .border(Border {
            color: palette.background.strong.color.scale_alpha(0.42),
            width: 1.0,
            ..border::rounded(12)
        })
        .shadow(Shadow {
            color: Color::BLACK.scale_alpha(0.10),
            offset: Vector::new(0.0, 1.0),
            blur_radius: 8.0,
        })
}

pub fn panel_subtle(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.background.weak.color.scale_alpha(0.55))
        .border(Border {
            color: palette.background.strong.color.scale_alpha(0.30),
            width: 1.0,
            ..border::rounded(10)
        })
}

pub fn panel_selected(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.primary.weak.color.scale_alpha(0.32))
        .border(Border {
            color: palette.primary.base.color.scale_alpha(0.95),
            width: 1.8,
            ..border::rounded(10)
        })
        .shadow(Shadow {
            color: palette.primary.strong.color.scale_alpha(0.22),
            offset: Vector::new(0.0, 2.0),
            blur_radius: 9.0,
        })
}

pub fn chip_neutral(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.background.strong.color.scale_alpha(0.35))
        .color(palette.background.base.text)
        .border(border::rounded(999))
}

pub fn chip_info(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.primary.weak.color.scale_alpha(0.40))
        .color(palette.primary.base.text)
        .border(border::rounded(999))
}

pub fn chip_success(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.success.weak.color.scale_alpha(0.40))
        .color(palette.success.base.text)
        .border(border::rounded(999))
}

pub fn chip_danger(theme: &IcedTheme) -> container::Style {
    let palette = theme.extended_palette();

    container::Style::default()
        .background(palette.danger.weak.color.scale_alpha(0.42))
        .color(palette.danger.base.text)
        .border(border::rounded(999))
}

pub fn button_primary(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: Some(Background::Color(palette.primary.base.color)),
        text_color: palette.primary.base.text,
        border: Border {
            color: palette.primary.strong.color.scale_alpha(0.6),
            width: 1.0,
            ..border::rounded(10)
        },
        shadow: Shadow {
            color: Color::BLACK.scale_alpha(0.12),
            offset: Vector::new(0.0, 1.0),
            blur_radius: 6.0,
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
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.45),
            background: base.background.map(|bg| match bg {
                Background::Color(color) => Background::Color(color.scale_alpha(0.55)),
                _ => bg,
            }),
            ..base
        },
    }
}

pub fn button_secondary(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: Some(Background::Color(
            palette.background.weak.color.scale_alpha(0.9),
        )),
        text_color: palette.background.base.text,
        border: Border {
            color: palette.background.strong.color.scale_alpha(0.52),
            width: 1.0,
            ..border::rounded(10)
        },
        shadow: Shadow::default(),
    };

    match status {
        button::Status::Active => base,
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.35),
            )),
            ..base
        },
        button::Status::Pressed => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.45),
            )),
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.45),
            ..base
        },
    }
}

pub fn button_danger(theme: &IcedTheme, status: button::Status) -> button::Style {
    let palette = theme.extended_palette();
    let base = button::Style {
        background: Some(Background::Color(palette.danger.base.color)),
        text_color: palette.danger.base.text,
        border: Border {
            color: palette.danger.strong.color.scale_alpha(0.60),
            width: 1.0,
            ..border::rounded(10)
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
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.45),
            ..base
        },
    }
}

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
                palette.background.strong.color.scale_alpha(0.25),
            )),
            border: Border {
                color: palette.background.strong.color.scale_alpha(0.45),
                ..base.border
            },
            ..base
        },
        button::Status::Pressed => button::Style {
            background: Some(Background::Color(
                palette.background.strong.color.scale_alpha(0.32),
            )),
            ..base
        },
        button::Status::Disabled => button::Style {
            text_color: base.text_color.scale_alpha(0.45),
            ..base
        },
    }
}

pub fn text_input_style(theme: &IcedTheme, status: text_input::Status) -> text_input::Style {
    let palette = theme.extended_palette();
    let base = text_input::Style {
        background: Background::Color(palette.background.weak.color.scale_alpha(0.70)),
        border: Border {
            color: palette.background.strong.color.scale_alpha(0.55),
            width: 1.0,
            ..border::rounded(10)
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
                color: palette.primary.weak.color.scale_alpha(0.65),
                ..base.border
            },
            ..base
        },
        text_input::Status::Focused => text_input::Style {
            background: Background::Color(palette.background.base.color.scale_alpha(0.98)),
            border: Border {
                color: palette.primary.base.color,
                width: 1.2,
                ..base.border
            },
            ..base
        },
        text_input::Status::Disabled => text_input::Style {
            value: base.value.scale_alpha(0.45),
            background: Background::Color(palette.background.weak.color.scale_alpha(0.45)),
            ..base
        },
    }
}
