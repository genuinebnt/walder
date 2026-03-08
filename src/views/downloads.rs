use iced::widget::{button, column, container, image, progress_bar, row, scrollable, text};
use iced::{Alignment, Element, Length};

use wallsetter_core::DownloadStatus;

use crate::app::{Message, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let tasks = app.download_tasks();
    let active_count = tasks
        .iter()
        .filter(|task| {
            matches!(
                task.status,
                DownloadStatus::Queued | DownloadStatus::Downloading
            )
        })
        .count();

    let mut tasks_list = column![].spacing(14);

    if tasks.is_empty() {
        tasks_list = tasks_list.push(
            container(
                column![
                    text("No downloads yet.").size(20),
                    text("Start a download from Search or Preview."),
                ]
                .spacing(6),
            )
            .padding(20)
            .style(container::rounded_box),
        );
    } else {
        for task in tasks {
            let progress = task.progress_percent().unwrap_or(0.0);

            let status_text = match task.status {
                DownloadStatus::Queued => "Queued".to_string(),
                DownloadStatus::Downloading => {
                    let mbps = task.speed_bps as f64 / 1_048_576.0;
                    format!("Downloading ({mbps:.2} MB/s)")
                }
                DownloadStatus::Completed => "Completed".to_string(),
                DownloadStatus::Failed => {
                    format!(
                        "Failed: {}",
                        task.error.as_deref().unwrap_or("Unknown error")
                    )
                }
                DownloadStatus::Cancelled => "Cancelled".to_string(),
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
                .style(container::rounded_box)
            } else {
                container(text("No preview"))
                    .width(Length::Fixed(100.0))
                    .height(Length::Fixed(70.0))
                    .align_x(iced::alignment::Horizontal::Center)
                    .align_y(iced::alignment::Vertical::Center)
                    .style(container::rounded_box)
            };

            let mut top = row![
                text(&task.filename).width(Length::Fill).size(16),
                text(status_text),
            ]
            .spacing(10)
            .align_y(Alignment::Center);

            if task.status == DownloadStatus::Completed {
                let mut path = crate::app::resolve_download_dir(&app.preferences().download_dir);
                path.push(&task.filename);
                top = top.push(
                    button("Set as Wallpaper")
                        .on_press(Message::SetWallpaper(path))
                        .style(button::secondary),
                );
            }

            let item = container(
                row![
                    thumb,
                    column![
                        top,
                        progress_bar(0.0..=100.0, progress),
                        text(format!("{:.1}% done", progress)).size(12),
                    ]
                    .spacing(6)
                    .width(Length::Fill),
                ]
                .spacing(12)
                .align_y(Alignment::Center),
            )
            .padding(14)
            .style(container::rounded_box);

            tasks_list = tasks_list.push(item);
        }
    }

    column![
        text("Downloads").size(30),
        text(format!("{active_count} active")).size(14),
        scrollable(tasks_list).height(Length::Fill),
    ]
    .spacing(14)
    .into()
}
