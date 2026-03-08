use iced::widget::{button, column, container, image, row, scrollable, text};
use iced::{Alignment, Element, Length};

use wallsetter_core::Wallpaper;

use crate::app::{Message, WallsetterApp};

pub fn view<'a>(app: &'a WallsetterApp, wp: &'a Wallpaper) -> Element<'a, Message> {
    let img_view: Element<'a, Message> = if let Some(handle) = app.get_full_image(&wp.id) {
        image(handle)
            .width(Length::Fill)
            .height(Length::Fixed(460.0))
            .content_fit(iced::ContentFit::Contain)
            .into()
    } else if let Some(handle) = app.get_thumbnail(&wp.id) {
        image(handle)
            .width(Length::Fill)
            .height(Length::Fixed(460.0))
            .content_fit(iced::ContentFit::Contain)
            .into()
    } else {
        container(text("Loading image preview...").size(18))
            .height(Length::Fixed(460.0))
            .align_x(iced::alignment::Horizontal::Center)
            .align_y(iced::alignment::Vertical::Center)
            .into()
    };

    let details = container(
        column![
            text(format!("ID: {}", wp.id)),
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
    .padding(14)
    .style(crate::theme::panel_subtle);

    let actions = row![
        button("Back")
            .on_press(Message::GoBack)
            .style(crate::theme::button_secondary),
        button("Download")
            .on_press(Message::DownloadSingle(wp.clone()))
            .style(crate::theme::button_secondary),
        button("Bookmark")
            .on_press(Message::AddBookmark(wp.clone()))
            .style(crate::theme::button_secondary),
        button("Set as Wallpaper")
            .on_press(Message::QuickSet(wp.clone()))
            .style(crate::theme::button_primary),
    ]
    .spacing(10)
    .align_y(Alignment::Center);

    scrollable(
        column![
            container(
                column![
                    text("Wallpaper Preview").size(26),
                    text("Inspect details, then download or apply instantly.").size(12),
                ]
                .spacing(2),
            )
            .padding(12)
            .style(crate::theme::panel),
            img_view,
            details,
            actions,
        ]
        .spacing(14),
    )
    .into()
}
