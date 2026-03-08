use iced::widget::{
    button, checkbox, column, container, image, pick_list, responsive, row, scrollable, text,
    text_input,
};
use iced::{Alignment, Element, Length};

use crate::app::{Message, WallsetterApp};

use wallsetter_core::{Category, Purity, Sorting};

pub fn view<'a>(app: &'a WallsetterApp) -> Element<'a, Message> {
    let filters = app.active_filters();
    let has_results = app
        .search_results()
        .is_some_and(|results| !results.wallpapers.is_empty());
    let selected_count = app.selected_wallpapers().len();

    let categories_section = container(
        column![
            text("Category").size(15),
            checkbox("General", filters.categories.contains(&Category::General))
                .on_toggle(|b| Message::ToggleCategory(Category::General, b)),
            checkbox("Anime", filters.categories.contains(&Category::Anime))
                .on_toggle(|b| Message::ToggleCategory(Category::Anime, b)),
            checkbox("People", filters.categories.contains(&Category::People))
                .on_toggle(|b| Message::ToggleCategory(Category::People, b)),
        ]
        .spacing(8),
    )
    .padding(12)
    .style(crate::theme::panel_subtle);

    let purity_section = container(
        column![
            text("Purity").size(15),
            checkbox("SFW", filters.purity.contains(&Purity::Sfw))
                .on_toggle(|b| Message::TogglePurity(Purity::Sfw, b)),
            checkbox("Sketchy", filters.purity.contains(&Purity::Sketchy))
                .on_toggle(|b| Message::TogglePurity(Purity::Sketchy, b)),
            checkbox("NSFW", filters.purity.contains(&Purity::Nsfw))
                .on_toggle(|b| Message::TogglePurity(Purity::Nsfw, b)),
        ]
        .spacing(8),
    )
    .padding(12)
    .style(crate::theme::panel_subtle);

    let sorting_options = vec![
        Sorting::DateAdded,
        Sorting::Relevance,
        Sorting::Random,
        Sorting::Views,
        Sorting::Favorites,
        Sorting::Toplist,
        Sorting::Hot,
    ];

    let sorting_section = container(
        column![
            text("Sort By").size(15),
            pick_list(
                sorting_options,
                Some(filters.sorting),
                Message::SortingChanged
            )
            .width(Length::Fill),
            button("Save as default")
                .on_press(Message::SaveFiltersAsDefault)
                .style(crate::theme::button_secondary),
        ]
        .spacing(10),
    )
    .padding(12)
    .style(crate::theme::panel_subtle);

    let sidebar = container(
        column![
            text("Filters").size(20),
            text("Narrow down results quickly.").size(12),
            categories_section,
            purity_section,
            sorting_section,
        ]
        .spacing(14)
        .width(Length::Fixed(240.0)),
    )
    .padding(12)
    .style(crate::theme::panel);

    let mut search_button = button("Search")
        .padding(10)
        .style(crate::theme::button_primary);
    if !app.is_searching() {
        search_button = search_button.on_press(Message::SubmitSearch);
    }

    let mut select_all_button = button("Select All")
        .padding(10)
        .style(crate::theme::button_secondary);
    if has_results {
        select_all_button = select_all_button.on_press(Message::SelectAll);
    }

    let grid_options: Vec<u32> = vec![2, 3, 4, 5, 6, 7, 8];
    let current_cols = app.preferences().grid_columns;

    let search_row = container(
        row![
            text_input("Search Wallhaven...", app.search_query())
                .on_input(Message::SearchQueryChanged)
                .on_submit(Message::SubmitSearch)
                .padding(10)
                .style(crate::theme::text_input_style)
                .width(Length::Fill),
            search_button,
            select_all_button,
            row![
                text("Grid"),
                pick_list(
                    grid_options,
                    Some(current_cols),
                    Message::GridColumnsChanged
                )
                .width(Length::Fixed(90.0)),
            ]
            .spacing(6)
            .align_y(Alignment::Center),
        ]
        .spacing(10)
        .align_y(Alignment::Center),
    )
    .padding(12)
    .style(crate::theme::panel);

    let results_content = responsive(move |size| {
        let mut results_ctn = column![].spacing(12);

        if app.is_searching() {
            results_ctn = results_ctn.push(
                container(text("Searching wallpapers...").size(18))
                    .padding(16)
                    .style(crate::theme::panel),
            );
        } else if let Some(results) = app.search_results() {
            let mut header = row![
                text(format!(
                    "{} results | page {}/{}",
                    results.total, results.current_page, results.last_page
                ))
                .size(16),
            ]
            .spacing(10)
            .align_y(Alignment::Center);

            let mut prev_btn = button("Previous").style(crate::theme::button_secondary);
            if results.current_page > 1 {
                prev_btn = prev_btn.on_press(Message::PreviousPage);
            }

            let mut next_btn = button("Next").style(crate::theme::button_secondary);
            if results.current_page < results.last_page {
                next_btn = next_btn.on_press(Message::NextPage);
            }

            header = header.push(prev_btn).push(next_btn);
            results_ctn = results_ctn.push(container(header).padding(8));

            if results.wallpapers.is_empty() {
                results_ctn = results_ctn.push(
                    container(text("No wallpapers matched this query."))
                        .padding(20)
                        .style(crate::theme::panel),
                );
                return scrollable(results_ctn).into();
            }

            let available_width = if size.width <= 0.0 { 900.0 } else { size.width };
            let item_width = 220.0;
            let max_columns = (available_width / (item_width + 18.0)).floor() as usize;
            let max_columns = if max_columns == 0 { 1 } else { max_columns };
            let desired = current_cols as usize;
            let columns = desired.min(max_columns);

            let mut grid_row = row![].spacing(16);
            let mut items_in_row = 0;

            for wp in &results.wallpapers {
                let thumbnail: Element<'_, Message> =
                    if let Some(handle) = app.get_thumbnail(&wp.id) {
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

                let id_clone = wp.id.clone();
                let is_selected = app.selected_wallpapers().contains(&wp.id);

                let item = container(
                    column![
                        button(thumbnail)
                            .on_press(Message::SwitchView(crate::app::View::Preview(wp.clone())))
                            .style(crate::theme::button_flat)
                            .width(Length::Fill),
                        row![
                            text(format!("{}x{}", wp.resolution.width, wp.resolution.height))
                                .size(12),
                            text(format!("Fav {}", wp.favorites)).size(12),
                            text(format!("Views {}", wp.views)).size(12),
                        ]
                        .spacing(8),
                        row![
                            checkbox("Select", is_selected).on_toggle(move |b| {
                                Message::ToggleSelection(id_clone.clone(), b)
                            }),
                            button("Set")
                                .on_press(Message::QuickSet(wp.clone()))
                                .style(crate::theme::button_secondary),
                            button("Bookmark")
                                .on_press(Message::AddBookmark(wp.clone()))
                                .style(crate::theme::button_secondary),
                        ]
                        .spacing(8)
                        .align_y(Alignment::Center),
                    ]
                    .spacing(8),
                )
                .padding(10)
                .width(Length::Fixed(item_width))
                .style(crate::theme::panel_subtle);

                grid_row = grid_row.push(item);
                items_in_row += 1;

                if items_in_row == columns {
                    results_ctn = results_ctn.push(grid_row);
                    grid_row = row![].spacing(16);
                    items_in_row = 0;
                }
            }

            if items_in_row > 0 {
                results_ctn = results_ctn.push(grid_row);
            }
        } else {
            results_ctn = results_ctn.push(
                container(
                    column![
                        text("Search for wallpapers").size(20),
                        text("Use any Wallhaven query, then preview, bookmark, or quick-set.")
                            .size(13),
                    ]
                    .spacing(8),
                )
                .padding(20)
                .style(crate::theme::panel),
            );
        }

        scrollable(results_ctn).into()
    });

    let mut main_content = column![search_row].spacing(14).width(Length::Fill);
    if selected_count > 0 {
        main_content = main_content.push(
            container(
                row![
                    text(format!("{selected_count} selected")).size(13),
                    button("Deselect")
                        .on_press(Message::DeselectAll)
                        .style(crate::theme::button_secondary),
                    button("Download Selected")
                        .on_press(Message::DownloadSelected)
                        .style(crate::theme::button_primary),
                ]
                .spacing(10)
                .align_y(Alignment::Center),
            )
            .padding(10)
            .style(crate::theme::panel),
        );
    }
    main_content = main_content.push(results_content);

    row![sidebar, main_content]
        .spacing(18)
        .width(Length::Fill)
        .into()
}
