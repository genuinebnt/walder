use iced::widget::{button, column, container, image, responsive, row, scrollable, text};
use iced::{Alignment, Element, Length};

use wallsetter_core::Wallpaper;

use crate::app::{Message, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp, wp: &'a Wallpaper) -> Element<'a, Message> {
    responsive(move |size| {
        let total_width = if size.width <= 0.0 {
            1100.0
        } else {
            size.width
        };
        let total_height = if size.height <= 0.0 {
            760.0
        } else {
            size.height
        };

        let info_width = (total_width * 0.25).clamp(260.0, 420.0);
        let preview_width = (total_width - info_width - 20.0).max(260.0);
        let preview_height = (total_height - 26.0).max(260.0);

        let natural_width = wp.resolution.width as f32;
        let natural_height = wp.resolution.height as f32;
        let frame_width = preview_width.min(natural_width);
        let frame_height = preview_height.min(natural_height);

        let img_view: Element<'a, Message> = if let Some(handle) = app.get_full_image(&wp.id) {
            image(handle)
                .width(Length::Fixed(frame_width))
                .height(Length::Fixed(frame_height))
                .content_fit(iced::ContentFit::Contain)
                .into()
        } else if let Some(handle) = app.get_thumbnail(&wp.id) {
            image(handle)
                .width(Length::Fixed(frame_width))
                .height(Length::Fixed(frame_height))
                .content_fit(iced::ContentFit::Contain)
                .into()
        } else {
            container(text("Loading image preview...").size(16))
                .width(Length::Fixed(frame_width))
                .height(Length::Fixed(frame_height))
                .align_x(iced::alignment::Horizontal::Center)
                .align_y(iced::alignment::Vertical::Center)
                .into()
        };

        let author_line: Element<'a, Message> = if let Some(username) = &wp.uploader {
            row![
                text("Author:"),
                button(text(format!("@{}", username)))
                    .on_press(Message::OpenAuthorProfile(username.clone()))
                    .style(crate::theme::button_secondary),
            ]
            .spacing(8)
            .align_y(Alignment::Center)
            .into()
        } else {
            text("Author: Unknown").into()
        };

        let mut tag_buttons = column![text("Image Tags").size(15)].spacing(6);
        if wp.tags.is_empty() {
            tag_buttons = tag_buttons.push(text("No tags available.").size(12));
        } else {
            for tag in &wp.tags {
                let tag_name = tag.name.clone();
                tag_buttons = tag_buttons.push(
                    button(text(format!("#{}", tag_name)))
                        .on_press(Message::SearchByTag(tag_name))
                        .style(crate::theme::button_secondary)
                        .width(Length::Fill),
                );
            }
        }

        let details = container(
            column![
                text(format!("ID: {}", wp.id)),
                author_line,
                text(format!(
                    "Resolution: {}x{}",
                    wp.resolution.width, wp.resolution.height
                )),
                text(format!("Category: {}", wp.category)),
                text(format!("Purity: {}", wp.purity)),
                text(format!("Views: {}", wp.views)),
                text(format!("Favorites: {}", wp.favorites)),
                text(format!("File size: {} bytes", wp.file_size)),
            ]
            .spacing(7),
        )
        .padding(12)
        .style(crate::theme::panel_subtle);

        let actions = column![
            button("Back")
                .on_press(Message::GoBack)
                .style(crate::theme::button_secondary)
                .width(Length::Fill),
            button("Download")
                .on_press(Message::DownloadSingle(wp.clone()))
                .style(crate::theme::button_secondary)
                .width(Length::Fill),
            button("Bookmark")
                .on_press(Message::AddBookmark(wp.clone()))
                .style(crate::theme::button_secondary)
                .width(Length::Fill),
            button("Set as Wallpaper")
                .on_press(Message::QuickSet(wp.clone()))
                .style(crate::theme::button_primary)
                .width(Length::Fill),
        ]
        .spacing(8);

        let info_panel = container(
            scrollable(
                column![
                    container(
                        column![
                            text("Wallpaper Preview").size(24),
                            text("Details, tags, and quick actions.").size(12),
                        ]
                        .spacing(2),
                    )
                    .padding(10)
                    .style(crate::theme::panel_subtle),
                    details,
                    container(tag_buttons)
                        .padding(12)
                        .style(crate::theme::panel_subtle),
                    actions,
                ]
                .spacing(12),
            )
            .height(Length::Fill),
        )
        .width(Length::Fixed(info_width))
        .height(Length::Fill)
        .padding(12)
        .style(crate::theme::panel);

        let preview_panel = container(
            container(img_view)
                .width(Length::Fill)
                .height(Length::Fill)
                .align_x(iced::alignment::Horizontal::Center)
                .align_y(iced::alignment::Vertical::Center),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .padding(12)
        .style(crate::theme::panel_subtle);

        row![info_panel, preview_panel]
            .spacing(12)
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    })
    .into()
}
