use iced::widget::{button, column, container, image, progress_bar, row, scrollable, text};
use iced::{Alignment, Element, Length, Theme};

use wallsetter_core::DownloadStatus;

use crate::app::{Message, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let tasks = app.download_tasks();

    let queued_count = tasks
        .iter()
        .filter(|task| task.status == DownloadStatus::Queued)
        .count();
    let downloading_count = tasks
        .iter()
        .filter(|task| task.status == DownloadStatus::Downloading)
        .count();
    let completed_count = tasks
        .iter()
        .filter(|task| task.status == DownloadStatus::Completed)
        .count();
    let failed_count = tasks
        .iter()
        .filter(|task| {
            matches!(
                task.status,
                DownloadStatus::Failed | DownloadStatus::Cancelled
            )
        })
        .count();

    let summary_chips = row![
        chip(
            format!("Queued {}", queued_count),
            crate::theme::chip_neutral
        ),
        chip(
            format!("Active {}", downloading_count),
            crate::theme::chip_info
        ),
        chip(
            format!("Done {}", completed_count),
            crate::theme::chip_success
        ),
        chip(
            format!("Failed {}", failed_count),
            crate::theme::chip_danger
        ),
    ]
    .spacing(8)
    .align_y(Alignment::Center);

    let has_finished = completed_count > 0 || failed_count > 0;
    let mut action_row = row![].spacing(8).align_y(Alignment::Center);
    if has_finished {
        action_row = action_row.push(
            button("Clear Finished")
                .on_press(Message::ClearCompletedDownloads)
                .style(crate::theme::button_secondary),
        );
    }
    if failed_count > 0 {
        action_row = action_row.push(
            button("Retry Failed")
                .on_press(Message::RetryFailedDownloads)
                .style(crate::theme::button_primary),
        );
    }

    let mut tasks_list = column![].spacing(12);

    if tasks.is_empty() {
        tasks_list = tasks_list.push(
            container(
                column![
                    text("No downloads yet.").size(18),
                    text("Start a download from Search or Preview.").size(13),
                ]
                .spacing(6),
            )
            .padding(18)
            .style(crate::theme::panel),
        );
    } else {
        for task in tasks {
            let progress = task.progress_percent().unwrap_or(0.0);

            let (status_label, status_style): (&str, fn(&Theme) -> container::Style) =
                match task.status {
                    DownloadStatus::Queued => ("Queued", crate::theme::chip_neutral),
                    DownloadStatus::Downloading => ("Active", crate::theme::chip_info),
                    DownloadStatus::Completed => ("Done", crate::theme::chip_success),
                    DownloadStatus::Failed | DownloadStatus::Cancelled => {
                        ("Failed", crate::theme::chip_danger)
                    }
                };

            let speed_label = if task.status == DownloadStatus::Downloading {
                let mbps = task.speed_bps as f64 / 1_048_576.0;
                format!("{mbps:.2} MB/s")
            } else {
                format!("{progress:.1}%")
            };

            let thumb = if let Some(handle) = app.get_thumbnail(&task.wallpaper_id) {
                container(
                    image(handle)
                        .width(Length::Fixed(100.0))
                        .height(Length::Fixed(70.0))
                        .content_fit(iced::ContentFit::Cover),
                )
                .width(Length::Fixed(100.0))
                .height(Length::Fixed(70.0))
                .style(crate::theme::panel_subtle)
            } else {
                container(text("No preview").size(11))
                    .width(Length::Fixed(100.0))
                    .height(Length::Fixed(70.0))
                    .align_x(iced::alignment::Horizontal::Center)
                    .align_y(iced::alignment::Vertical::Center)
                    .style(crate::theme::panel_subtle)
            };

            let mut top = row![
                text(&task.filename).width(Length::Fill).size(14),
                chip(status_label, status_style),
                chip(speed_label, crate::theme::chip_neutral),
            ]
            .spacing(8)
            .align_y(Alignment::Center);

            if task.status == DownloadStatus::Completed {
                let mut path = crate::app::resolve_download_dir(&app.preferences().download_dir);
                path.push(&task.filename);
                top = top.push(
                    button("Set")
                        .on_press(Message::SetWallpaper(path))
                        .style(crate::theme::button_secondary),
                );
            }

            let mut task_body = column![top, progress_bar(0.0..=100.0, progress)]
                .spacing(6)
                .width(Length::Fill);

            if task.status == DownloadStatus::Failed {
                task_body = task_body.push(
                    text(task.error.as_deref().unwrap_or("Unknown error"))
                        .size(11)
                        .color([0.89, 0.30, 0.30]),
                );
            }

            let item = container(
                row![thumb, task_body]
                    .spacing(12)
                    .align_y(Alignment::Center),
            )
            .padding(12)
            .style(crate::theme::panel_subtle);

            tasks_list = tasks_list.push(item);
        }
    }

    column![
        container(
            column![
                text("Downloads").size(26),
                text("Track progress and set completed wallpapers quickly.").size(12),
                summary_chips,
                action_row,
            ]
            .spacing(8)
        )
        .padding(12)
        .style(crate::theme::panel),
        scrollable(tasks_list).height(Length::Fill),
    ]
    .spacing(12)
    .into()
}

fn chip<'a>(
    label: impl Into<String>,
    style: fn(&Theme) -> container::Style,
) -> Element<'a, Message> {
    container(text(label.into()).size(11))
        .padding([4, 10])
        .style(style)
        .into()
}
