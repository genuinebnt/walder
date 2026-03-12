use iced::widget::{button, column, container, image, progress_bar, row, scrollable, text, text_input};
use iced::{Alignment, Element, Length, Theme};

use wallsetter_core::DownloadStatus;

use crate::app::{DownloadViewTab, Message, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let download_folders = app.download_folders();
    let current_tab = app.download_view_tab();

    // ── Sidebar ──────────────────────────────────────────────────────────
    let mut sidebar_col = column![].spacing(4);

    // "Active Downloads" tab
    let queue_style = if current_tab == &DownloadViewTab::Queue {
        crate::theme::button_primary
    } else {
        crate::theme::button_secondary
    };
    sidebar_col = sidebar_col.push(
        button(text("Active Downloads").size(13))
            .on_press(Message::SetDownloadViewTab(DownloadViewTab::Queue))
            .style(queue_style)
            .width(Length::Fill),
    );

    // "All Files" tab
    let all_style = if current_tab == &DownloadViewTab::Library(None) {
        crate::theme::button_primary
    } else {
        crate::theme::button_secondary
    };
    sidebar_col = sidebar_col.push(
        button(text("All Files").size(13))
            .on_press(Message::SetDownloadViewTab(DownloadViewTab::Library(None)))
            .style(all_style)
            .width(Length::Fill),
    );

    // Named folders
    for folder in download_folders {
        let tab = DownloadViewTab::Library(Some(folder.id));
        let style = if current_tab == &tab {
            crate::theme::button_primary
        } else {
            crate::theme::button_secondary
        };
        sidebar_col = sidebar_col.push(
            button(text(&folder.name).size(13))
                .on_press(Message::SetDownloadViewTab(tab))
                .style(style)
                .width(Length::Fill),
        );
    }

    // New folder form
    sidebar_col = sidebar_col.push(
        container(
            column![
                text("New Folder").size(12),
                text_input("Folder name…", app.new_download_folder_name())
                    .on_input(Message::NewDownloadFolderNameChanged)
                    .on_submit(Message::CreateDownloadFolder)
                    .padding(6)
                    .style(crate::theme::text_input_style)
                    .width(Length::Fill),
                button("Create")
                    .on_press(Message::CreateDownloadFolder)
                    .style(crate::theme::button_primary)
                    .width(Length::Fill),
            ]
            .spacing(6),
        )
        .padding(8)
        .style(crate::theme::panel_subtle),
    );

    let sidebar = container(
        scrollable(sidebar_col)
            .height(Length::Fill)
            .style(crate::theme::scrollbar),
    )
    .width(Length::Fixed(180.0))
    .height(Length::Fill)
    .padding(10)
    .style(crate::theme::panel);

    // ── Main content ─────────────────────────────────────────────────────
    let main_content: Element<'a, Message> = match current_tab {
        DownloadViewTab::Queue => queue_view(app),
        DownloadViewTab::Library(_) => library_view(app),
    };

    let header = container(
        column![
            text("Downloads").size(22),
            text("Organize and manage your downloaded wallpapers.").size(12),
        ]
        .spacing(4),
    )
    .padding(12)
    .style(crate::theme::panel);

    column![
        header,
        row![
            sidebar,
            container(main_content)
                .width(Length::Fill)
                .height(Length::Fill),
        ]
        .spacing(12)
        .height(Length::Fill),
    ]
    .spacing(12)
    .into()
}

fn queue_view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let tasks = app.download_tasks();

    let queued_count = tasks.iter().filter(|t| t.status == DownloadStatus::Queued).count();
    let downloading_count = tasks.iter().filter(|t| t.status == DownloadStatus::Downloading).count();
    let completed_count = tasks.iter().filter(|t| t.status == DownloadStatus::Completed).count();
    let failed_count = tasks
        .iter()
        .filter(|t| matches!(t.status, DownloadStatus::Failed | DownloadStatus::Cancelled))
        .count();

    let summary = row![
        chip(format!("Queued {queued_count}"), crate::theme::chip_neutral),
        chip(format!("Active {downloading_count}"), crate::theme::chip_info),
        chip(format!("Done {completed_count}"), crate::theme::chip_success),
        chip(format!("Failed {failed_count}"), crate::theme::chip_danger),
    ]
    .spacing(8)
    .align_y(Alignment::Center);

    let mut action_row = row![].spacing(8);
    if completed_count > 0 || failed_count > 0 {
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

    let mut tasks_list = column![
        container(column![summary, action_row].spacing(8))
            .padding(10)
            .style(crate::theme::panel_subtle),
    ]
    .spacing(10);

    if tasks.is_empty() {
        tasks_list = tasks_list.push(
            container(
                column![
                    text("No active downloads.").size(16),
                    text("Start a download from Search or Preview.").size(12),
                ]
                .spacing(6),
            )
            .padding(18)
            .style(crate::theme::panel_subtle),
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
                        .width(Length::Fixed(90.0))
                        .height(Length::Fixed(64.0))
                        .content_fit(iced::ContentFit::Cover),
                )
                .style(crate::theme::panel_subtle)
            } else {
                container(text("No preview").size(11))
                    .width(Length::Fixed(90.0))
                    .height(Length::Fixed(64.0))
                    .align_x(iced::alignment::Horizontal::Center)
                    .align_y(iced::alignment::Vertical::Center)
                    .style(crate::theme::panel_subtle)
            };

            let mut top_row = row![
                text(&task.filename).width(Length::Fill).size(13),
                chip(status_label, status_style),
                chip(speed_label, crate::theme::chip_neutral),
            ]
            .spacing(8)
            .align_y(Alignment::Center);

            if task.status == DownloadStatus::Completed {
                let mut path =
                    crate::app::resolve_download_dir(&app.preferences().download_dir);
                path.push(&task.filename);
                top_row = top_row.push(
                    button("Set")
                        .on_press(Message::SetWallpaper(path))
                        .style(crate::theme::button_secondary),
                );
            }

            let mut body = column![top_row, progress_bar(0.0..=100.0, progress)]
                .spacing(6)
                .width(Length::Fill);

            if task.status == DownloadStatus::Failed {
                body = body.push(
                    text(task.error.as_deref().unwrap_or("Unknown error"))
                        .size(11)
                        .color([0.89, 0.30, 0.30]),
                );
            }

            tasks_list = tasks_list.push(
                container(row![thumb, body].spacing(10).align_y(Alignment::Center))
                    .padding(10)
                    .style(crate::theme::panel_subtle),
            );
        }
    }

    scrollable(tasks_list)
        .height(Length::Fill)
        .style(crate::theme::scrollbar)
        .into()
}

fn library_view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let all_items = app.local_wallpapers_for_display();
    let download_folders = app.download_folders();

    if all_items.is_empty() {
        return container(
            container(text("No downloaded wallpapers here yet.").size(15))
                .padding(20)
                .style(crate::theme::panel_subtle),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .padding(12)
        .into();
    }

    let total_items = all_items.len();
    let page_size = 20;
    let total_pages = (total_items + page_size - 1) / page_size;
    let total_pages = total_pages.max(1);

    let current_page = app.downloads_page().clamp(1, total_pages);

    let start_idx = (current_page - 1) * page_size;
    let end_idx = (start_idx + page_size).min(total_items);

    let items = &all_items[start_idx..end_idx];

    let mut list = column![].spacing(10);

    if total_pages > 1 {
        let mut header = row![
            text(format!(
                "{} results | page {}/{}",
                total_items, current_page, total_pages
            ))
            .size(13),
        ]
        .spacing(10)
        .align_y(Alignment::Center);

        let mut prev_btn = button("Previous").style(crate::theme::button_secondary);
        if current_page > 1 {
            prev_btn = prev_btn.on_press(Message::PreviousDownloadsPage);
        }

        let mut next_btn = button("Next").style(crate::theme::button_secondary);
        if current_page < total_pages {
            next_btn = next_btn.on_press(Message::NextDownloadsPage);
        }

        header = header.push(prev_btn).push(next_btn);
        
        list = list.push(container(header));
    }

    for lw in items {
        // Thumbnail: try cached thumbnail, fall back to local file
        let thumb: Element<'a, Message> = if let Some(handle) = app.get_thumbnail(&lw.wallpaper_id)
        {
            image(handle)
                .width(Length::Fixed(96.0))
                .height(Length::Fixed(68.0))
                .content_fit(iced::ContentFit::Cover)
                .into()
        } else {
            let path = lw.local_path.clone();
            image(iced::widget::image::Handle::from_path(path))
                .width(Length::Fixed(96.0))
                .height(Length::Fixed(68.0))
                .content_fit(iced::ContentFit::Cover)
                .into()
        };

        // "Move to" folder buttons
        let lw_id = lw.id;
        let current_folder_id = lw.folder_id;
        let mut move_row = row![].spacing(4);
        // "Move to root" button (only show if currently in a folder)
        if current_folder_id.is_some() {
            move_row = move_row.push(
                button(text("→ Root").size(11))
                    .on_press(Message::MoveLocalWallpaper(lw_id, None))
                    .style(crate::theme::button_secondary),
            );
        }
        for folder in download_folders {
            if Some(folder.id) != current_folder_id {
                move_row = move_row.push(
                    button(text(format!("→ {}", folder.name)).size(11))
                        .on_press(Message::MoveLocalWallpaper(lw_id, Some(folder.id)))
                        .style(crate::theme::button_secondary),
                );
            }
        }

        let local_path = lw.local_path.clone();
        let info = column![
            text(&lw.filename).size(13).width(Length::Fill),
            text(format!("{}×{}", lw.resolution.width, lw.resolution.height)).size(11),
            row![
                button("Set as Wallpaper")
                    .on_press(Message::QuickSetLocalWallpaper(local_path))
                    .style(crate::theme::button_primary),
                button("✕")
                    .on_press(Message::DeleteLocalWallpaper(lw_id))
                    .style(crate::theme::button_danger),
            ]
            .spacing(6),
            move_row,
        ]
        .spacing(6)
        .width(Length::Fill);

        list = list.push(
            container(
                row![
                    container(thumb).style(crate::theme::panel_subtle),
                    info,
                ]
                .spacing(10)
                .align_y(Alignment::Start),
            )
            .padding(10)
            .style(crate::theme::panel_subtle),
        );
    }

    scrollable(list)
        .height(Length::Fill)
        .style(crate::theme::scrollbar)
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
