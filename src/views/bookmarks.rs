use iced::widget::{button, column, container, image, responsive, row, scrollable, text, text_input};
use iced::{Alignment, Element, Length};

use crate::app::{Message, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let bookmarks = app.bookmarks_for_display();
    let all_folders = app.bookmark_folders();
    let selected_folder = app.selected_folder();

    // ── Header ──────────────────────────────────────────────────────────────
    let total_count = app.bookmarks().len();
    let folder_count = all_folders.len();

    let header = container(
        column![
            row![
                column![
                    text("Bookmarks").size(26),
                    text("Saved wallpapers you can reopen anytime.").size(12),
                    container(text(format!(
                        "{} saved | {} collections",
                        total_count, folder_count
                    )))
                    .padding([4, 10])
                    .style(crate::theme::chip_neutral),
                ]
                .spacing(6)
                .width(Length::Fill),
            ]
            .spacing(12)
            .align_y(Alignment::Center),
        ]
        .spacing(8),
    )
    .padding(12)
    .style(crate::theme::panel);

    // ── Collection sidebar ──────────────────────────────────────────────────
    let mut folder_col = column![].spacing(6);

    // "All" button
    let all_style = if selected_folder.is_none() {
        crate::theme::button_primary
    } else {
        crate::theme::button_secondary
    };
    folder_col = folder_col.push(
        button("All")
            .on_press(Message::SelectFolder(None))
            .style(all_style)
            .width(Length::Fill),
    );

    for folder in all_folders {
        let style = if selected_folder == Some(folder.id) {
            crate::theme::button_primary
        } else {
            crate::theme::button_secondary
        };
        folder_col = folder_col.push(
            button(text(&folder.name).size(13))
                .on_press(Message::SelectFolder(Some(folder.id)))
                .style(style)
                .width(Length::Fill),
        );
    }

    // New collection form
    folder_col = folder_col.push(
        container(
            column![
                text("New Collection").size(12),
                text_input("Collection name…", app.new_collection_name())
                    .on_input(Message::NewCollectionNameChanged)
                    .on_submit(Message::CreateCollection)
                    .padding(6)
                    .style(crate::theme::text_input_style)
                    .width(Length::Fill),
                button("Create")
                    .on_press(Message::CreateCollection)
                    .style(crate::theme::button_primary)
                    .width(Length::Fill),
            ]
            .spacing(6),
        )
        .padding(8)
        .style(crate::theme::panel_subtle),
    );

    let sidebar = container(scrollable(folder_col).height(Length::Fill).style(crate::theme::scrollbar))
        .width(Length::Fixed(180.0))
        .height(Length::Fill)
        .padding(10)
        .style(crate::theme::panel);

    // ── Grid ────────────────────────────────────────────────────────────────
    if bookmarks.is_empty() {
        let empty_msg = if selected_folder.is_some() {
            "No wallpapers in this collection."
        } else {
            "No bookmarks yet. Open any wallpaper and click Bookmark."
        };

        let content = column![
            header,
            row![
                sidebar,
                container(
                    container(text(empty_msg).size(16))
                        .padding(20)
                        .style(crate::theme::panel),
                )
                .width(Length::Fill)
                .height(Length::Fill),
            ]
            .spacing(12)
            .height(Length::Fill),
        ]
        .spacing(12);

        return content.into();
    }

    let bookmarks_owned: Vec<_> = bookmarks.into_iter().cloned().collect();
    let grid = responsive(move |size| {
        let available_width = if size.width <= 0.0 { 900.0 } else { size.width };
        let item_width = 220.0;
        let columns = ((available_width / (item_width + 16.0)).floor() as usize).max(1);

        let mut results_col = column![].spacing(16);
        let mut grid_row = row![].spacing(16);
        let mut items_in_row = 0;

        for bm in &bookmarks_owned {
            let thumb: Element<'_, Message> =
                if let Some(handle) = app.get_thumbnail(&bm.wallpaper_id) {
                    image(handle)
                        .width(Length::Fill)
                        .height(Length::Fixed(148.0))
                        .content_fit(iced::ContentFit::Cover)
                        .into()
                } else {
                    container(text("Loading preview..."))
                        .width(Length::Fill)
                        .height(Length::Fixed(148.0))
                        .align_x(iced::alignment::Horizontal::Center)
                        .align_y(iced::alignment::Vertical::Center)
                        .into()
                };

            let bm_id = bm.id;
            let card = container(
                column![
                    container(thumb)
                        .width(Length::Fill)
                        .style(crate::theme::panel_subtle),
                    text(format!("{}x{}", bm.resolution.width, bm.resolution.height)).size(11),
                    text(format!("ID {}", short_id(&bm.wallpaper_id))).size(10),
                    row![
                        button("Open")
                            .on_press(Message::OpenBookmark(bm.wallpaper_id.clone()))
                            .style(crate::theme::button_secondary),
                        button("✕")
                            .on_press(Message::RemoveBookmark(bm_id))
                            .style(crate::theme::button_danger),
                    ]
                    .spacing(8)
                    .align_y(Alignment::Center),
                ]
                .spacing(8),
            )
            .padding(10)
            .width(Length::Fixed(item_width))
            .style(crate::theme::panel_subtle);

            grid_row = grid_row.push(card);
            items_in_row += 1;

            if items_in_row == columns {
                results_col = results_col.push(grid_row);
                grid_row = row![].spacing(16);
                items_in_row = 0;
            }
        }

        if items_in_row > 0 {
            results_col = results_col.push(grid_row);
        }

        scrollable(results_col)
            .height(Length::Fill)
            .style(crate::theme::scrollbar)
            .into()
    });

    column![
        header,
        row![
            sidebar,
            container(grid).width(Length::Fill).height(Length::Fill),
        ]
        .spacing(12)
        .height(Length::Fill),
    ]
    .spacing(12)
    .into()
}

fn short_id(id: &str) -> String {
    if id.chars().count() > 12 {
        format!("{}...", id.chars().take(12).collect::<String>())
    } else {
        id.to_string()
    }
}
