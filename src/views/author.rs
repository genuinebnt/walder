use iced::widget::{button, column, container, image, responsive, row, scrollable, text};
use iced::{Alignment, Element, Length};

use crate::app::{Message, View, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    responsive(move |size| {
        let username = app.author_username().unwrap_or("unknown");
        let results = app.author_results();
        let can_download_page = results.is_some_and(|r| !r.wallpapers.is_empty());

        let mut toolbar = row![
            button("Back")
                .on_press(Message::GoBack)
                .style(crate::theme::button_secondary),
        ]
        .spacing(8)
        .align_y(Alignment::Center);

        if can_download_page {
            toolbar = toolbar.push(
                button("Download This Page")
                    .on_press(Message::DownloadAuthorWorks)
                    .style(crate::theme::button_primary),
            );
            toolbar = toolbar.push(
                button("Download All Works")
                    .on_press(Message::DownloadAllAuthorWorks)
                    .style(crate::theme::button_secondary),
            );
        }

        let mut content = column![
            container(column![
                row![
                    column![
                        text(format!("@{username}")).size(26),
                        text("Author profile and published works.").size(12),
                    ]
                    .spacing(2)
                    .width(Length::Fill),
                    toolbar,
                ]
                .align_y(Alignment::Center)
            ])
            .padding(12)
            .style(crate::theme::panel),
        ]
        .spacing(12);

        if app.is_loading_author() {
            content = content.push(
                container(text("Loading author works...").size(16))
                    .padding(16)
                    .style(crate::theme::panel),
            );
            return scrollable(content).into();
        }

        match results {
            Some(results) if !results.wallpapers.is_empty() => {
                let mut prev_btn = button("Previous").style(crate::theme::button_secondary);
                if results.current_page > 1 {
                    prev_btn = prev_btn.on_press(Message::AuthorPreviousPage);
                }

                let mut next_btn = button("Next").style(crate::theme::button_secondary);
                if results.current_page < results.last_page {
                    next_btn = next_btn.on_press(Message::AuthorNextPage);
                }

                content = content.push(
                    container(
                        row![
                            text(format!(
                                "{} results | page {}/{}",
                                results.total, results.current_page, results.last_page
                            ))
                            .size(14),
                            prev_btn,
                            next_btn,
                        ]
                        .spacing(10)
                        .align_y(Alignment::Center),
                    )
                    .padding(10)
                    .style(crate::theme::panel_subtle),
                );

                let available_width = if size.width <= 0.0 { 900.0 } else { size.width };
                let spacing = 16.0;
                let min_item_width = 180.0;
                let desired = app.preferences().grid_columns as usize;
                let mut columns = desired.max(1);

                while columns > 1 {
                    let total_spacing = spacing * (columns.saturating_sub(1) as f32);
                    let candidate_width = (available_width - total_spacing) / columns as f32;
                    if candidate_width >= min_item_width {
                        break;
                    }
                    columns -= 1;
                }

                let total_spacing = spacing * (columns.saturating_sub(1) as f32);
                let item_width =
                    ((available_width - total_spacing) / columns as f32).max(min_item_width);
                let thumbnail_height = (item_width * 0.62).clamp(100.0, 220.0);

                let mut rows = column![].spacing(16);
                let mut current_row = row![].spacing(spacing);
                let mut items_in_row = 0;

                for wp in &results.wallpapers {
                    let thumbnail: Element<'_, Message> =
                        if let Some(handle) = app.get_thumbnail(&wp.id) {
                            image(handle)
                                .width(Length::Fill)
                                .height(Length::Fixed(thumbnail_height))
                                .content_fit(iced::ContentFit::Cover)
                                .into()
                        } else {
                            container(text("Loading preview..."))
                                .width(Length::Fill)
                                .height(Length::Fixed(thumbnail_height))
                                .align_x(iced::alignment::Horizontal::Center)
                                .align_y(iced::alignment::Vertical::Center)
                                .into()
                        };

                    let card = container(
                        column![
                            button(thumbnail)
                                .on_press(Message::SwitchView(View::Preview(wp.clone())))
                                .style(crate::theme::button_flat)
                                .width(Length::Fill),
                            row![
                                text(format!("{}x{}", wp.resolution.width, wp.resolution.height))
                                    .size(11),
                                text(format!("Fav {}", wp.favorites)).size(11),
                            ]
                            .spacing(8),
                            row![
                                button("Download")
                                    .on_press(Message::DownloadSingle(wp.clone()))
                                    .style(crate::theme::button_secondary),
                                button("Bookmark")
                                    .on_press(Message::AddBookmark(wp.clone()))
                                    .style(crate::theme::button_secondary),
                            ]
                            .spacing(8),
                        ]
                        .spacing(8),
                    )
                    .padding(10)
                    .width(Length::Fixed(item_width))
                    .style(crate::theme::panel_subtle);

                    current_row = current_row.push(card);
                    items_in_row += 1;

                    if items_in_row == columns {
                        rows = rows.push(current_row);
                        current_row = row![].spacing(spacing);
                        items_in_row = 0;
                    }
                }

                if items_in_row > 0 {
                    rows = rows.push(current_row);
                }

                content = content.push(rows);
            }
            _ => {
                content = content.push(
                    container(
                        column![
                            text("No public works found for this author.").size(16),
                            text("Try another author or adjust API/purity settings.").size(12),
                        ]
                        .spacing(6),
                    )
                    .padding(16)
                    .style(crate::theme::panel),
                );
            }
        }

        scrollable(content).into()
    })
    .into()
}
