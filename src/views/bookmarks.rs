use iced::widget::{button, column, container, image, responsive, row, scrollable, text};
use iced::{Alignment, Element, Length};

use crate::app::{Message, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let bookmarks = app.bookmarks();
    let folder_count = app.bookmark_folders().len();

    let mut header = column![
        container(
            row![
                column![
                    text("Bookmarks").size(26),
                    text("Saved wallpapers you can reopen anytime.").size(12),
                ]
                .spacing(2)
                .width(Length::Fill),
                text(format!(
                    "{} saved | {} folders",
                    bookmarks.len(),
                    folder_count
                ))
                .size(12),
            ]
            .align_y(Alignment::Center),
        )
        .padding(12)
        .style(crate::theme::panel)
    ]
    .spacing(12);

    if bookmarks.is_empty() {
        header = header.push(
            container(
                column![
                    text("No bookmarks yet.").size(18),
                    text("Open any wallpaper and click Bookmark.").size(12),
                ]
                .spacing(6),
            )
            .padding(20)
            .style(crate::theme::panel),
        );
        return header.into();
    }

    let grid = responsive(move |size| {
        let available_width = if size.width <= 0.0 { 900.0 } else { size.width };
        let item_width = 220.0;
        let columns = (available_width / (item_width + 16.0)).floor() as usize;
        let columns = if columns == 0 { 1 } else { columns };

        let mut results_col = column![].spacing(16);
        let mut grid_row = row![].spacing(16);
        let mut items_in_row = 0;

        for bm in bookmarks {
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

            let card = container(
                column![
                    container(thumb)
                        .width(Length::Fill)
                        .style(crate::theme::panel_subtle),
                    text(format!("{}x{}", bm.resolution.width, bm.resolution.height)).size(11),
                    row![
                        button("Open")
                            .on_press(Message::OpenBookmark(bm.wallpaper_id.clone()))
                            .style(crate::theme::button_secondary),
                        text(format!("ID {}", bm.wallpaper_id)).size(11),
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

        scrollable(results_col).height(Length::Fill).into()
    });

    header.push(grid).into()
}
