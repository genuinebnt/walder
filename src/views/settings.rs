use iced::widget::{button, checkbox, column, container, row, scrollable, text, text_input};
use iced::{Alignment, Element, Length};

use wallsetter_core::SchedulerSource;

use crate::app::{Message, SettingsMessage, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let prefs = app.preferences();

    let api_key_input = row![
        text("Wallhaven API Key").width(Length::Fixed(190.0)),
        text_input("Optional API key", prefs.api_key.as_deref().unwrap_or(""))
            .on_input(|s| Message::SettingsChanged(SettingsMessage::ApiKeyChanged(s)))
            .secure(true)
            .padding(10)
            .size(14)
            .style(crate::theme::text_input_style)
            .width(Length::Fill),
    ]
    .spacing(12)
    .align_y(Alignment::Center);

    let download_dir_input = row![
        text("Download directory").width(Length::Fixed(190.0)),
        text_input("Path to save wallpapers", &prefs.download_dir)
            .on_input(|s| Message::SettingsChanged(SettingsMessage::DownloadDirChanged(s)))
            .padding(10)
            .size(14)
            .style(crate::theme::text_input_style)
            .width(Length::Fill),
    ]
    .spacing(12)
    .align_y(Alignment::Center);

    let max_parallel_input = row![
        text("Max parallel downloads").width(Length::Fixed(190.0)),
        text_input("1-10", &prefs.max_parallel_downloads.to_string())
            .on_input(|s| Message::SettingsChanged(SettingsMessage::MaxParallelChanged(s)))
            .padding(10)
            .size(14)
            .style(crate::theme::text_input_style)
            .width(Length::Fixed(120.0)),
        text("(applies when queue is idle)").size(11),
    ]
    .spacing(12)
    .align_y(Alignment::Center);

    let current_source = &prefs.scheduler.source;
    let is_download_dir_source = matches!(current_source, SchedulerSource::DownloadDir);

    let mut source_col = column![
        text("Wallpaper Source").size(13),
        button(text(if is_download_dir_source {
            "✓ Download Directory"
        } else {
            "Download Directory"
        }).size(13))
        .on_press(Message::SettingsChanged(
            SettingsMessage::SchedulerSourceChanged(SchedulerSource::DownloadDir),
        ))
        .style(if is_download_dir_source {
            crate::theme::button_primary
        } else {
            crate::theme::button_secondary
        })
        .width(Length::Fill),
    ]
    .spacing(6);

    for folder in app.bookmark_folders() {
        let is_selected = matches!(current_source, SchedulerSource::BookmarkFolder(id) if *id == folder.id);
        let label = if is_selected {
            format!("✓ Collection: {}", folder.name)
        } else {
            format!("Collection: {}", folder.name)
        };
        source_col = source_col.push(
            button(text(label).size(13))
                .on_press(Message::SettingsChanged(
                    SettingsMessage::SchedulerSourceChanged(SchedulerSource::BookmarkFolder(
                        folder.id,
                    )),
                ))
                .style(if is_selected {
                    crate::theme::button_primary
                } else {
                    crate::theme::button_secondary
                })
                .width(Length::Fill),
        );
    }

    let scheduler_section = container(
        column![
            text("Scheduler").size(22),
            checkbox(
                "Enable automatic wallpaper rotation",
                prefs.scheduler.enabled
            )
            .on_toggle(|b| Message::SettingsChanged(SettingsMessage::SchedulerEnabledChanged(b))),
            row![
                text("Interval (minutes)").width(Length::Fixed(190.0)),
                text_input("e.g. 30", &prefs.scheduler.interval_minutes.to_string())
                    .on_input(|s| Message::SettingsChanged(
                        SettingsMessage::SchedulerIntervalChanged(s)
                    ))
                    .padding(10)
                    .size(14)
                    .style(crate::theme::text_input_style)
                    .width(Length::Fixed(120.0)),
            ]
            .spacing(12)
            .align_y(Alignment::Center),
            checkbox("Shuffle wallpapers", prefs.scheduler.shuffle).on_toggle(|b| {
                Message::SettingsChanged(SettingsMessage::SchedulerShuffleChanged(b))
            }),
            container(source_col)
                .padding(10)
                .style(crate::theme::panel_subtle),
        ]
        .spacing(12),
    )
    .padding(14)
    .style(crate::theme::panel_subtle);

    let content = column![
        container(
            column![
                text("Settings").size(26),
                text("Tune API access, downloads, and scheduler behavior.").size(12),
            ]
            .spacing(2),
        )
        .padding(12)
        .style(crate::theme::panel),
        container(column![api_key_input, download_dir_input, max_parallel_input].spacing(12))
            .padding(14)
            .style(crate::theme::panel_subtle),
        scheduler_section,
        button("Save Preferences")
            .on_press(Message::SettingsChanged(SettingsMessage::Save))
            .style(crate::theme::button_primary),
    ]
    .spacing(14);

    scrollable(content).into()
}
