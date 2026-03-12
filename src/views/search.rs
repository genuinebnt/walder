use iced::widget::text::Wrapping as TextWrapping;
use iced::widget::{
    button, checkbox, column, container, image, mouse_area, pick_list, responsive, row, scrollable,
    text, text_input,
};
use crate::app::SEARCH_SCROLL_ID;
use iced::{Alignment, Element, Length};

use crate::app::{Message, ResolutionMode, WallsetterApp};

use wallsetter_core::{Category, Purity, Resolution, SortOrder, Sorting, ToplistRange};

const COLOR_PRESETS: [&str; 29] = [
    "660000", "990000", "cc0000", "cc3333", "ea4c88", "993399", "663399", "333399", "0066cc",
    "0099cc", "66cccc", "77cc33", "669900", "336600", "666600", "999900", "cccc33", "ffff00",
    "ffcc33", "ff9900", "ff6600", "cc6633", "996633", "663300", "000000", "999999", "cccccc",
    "ffffff", "424153",
];

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
    let order_options = vec![SortOrder::Desc, SortOrder::Asc];
    let toplist_range_options = vec![
        ToplistRange::OneDay,
        ToplistRange::ThreeDays,
        ToplistRange::OneWeek,
        ToplistRange::OneMonth,
        ToplistRange::ThreeMonths,
        ToplistRange::SixMonths,
        ToplistRange::OneYear,
    ];

    let mut sorting_content = column![
        text("Sort By").size(15),
        pick_list(
            sorting_options,
            Some(filters.sorting),
            Message::SortingChanged
        )
        .width(Length::Fill),
        row![
            text("Order").size(12).width(Length::FillPortion(1)),
            pick_list(
                order_options,
                Some(filters.order),
                Message::SortOrderChanged
            )
            .width(Length::FillPortion(2)),
        ]
        .spacing(8)
        .align_y(Alignment::Center),
    ]
    .spacing(10);

    if filters.sorting == Sorting::Toplist {
        sorting_content = sorting_content.push(
            row![
                text("Toplist").size(12).width(Length::FillPortion(1)),
                pick_list(
                    toplist_range_options,
                    Some(filters.toplist_range.unwrap_or(ToplistRange::SixMonths)),
                    Message::ToplistRangeChanged,
                )
                .width(Length::FillPortion(2)),
            ]
            .spacing(8)
            .align_y(Alignment::Center),
        );
    }

    sorting_content = sorting_content.push(
        button("Save as default")
            .on_press(Message::SaveFiltersAsDefault)
            .style(crate::theme::button_secondary),
    );

    let sorting_section = container(sorting_content)
        .padding(12)
        .style(crate::theme::panel_subtle);

    let resolution_mode_options = vec![ResolutionMode::AtLeast, ResolutionMode::Exactly];
    let resolution_mode = app.resolution_mode();
    let mut resolution_controls = column![
        row![
            text("Mode").size(12).width(Length::FillPortion(1)),
            pick_list(
                resolution_mode_options,
                Some(resolution_mode),
                Message::ResolutionModeChanged
            )
            .width(Length::FillPortion(2)),
        ]
        .spacing(8)
        .align_y(Alignment::Center),
    ]
    .spacing(8);

    if resolution_mode == ResolutionMode::AtLeast {
        resolution_controls = resolution_controls.push(
            text_input("1920x1080", app.atleast_resolution_input())
                .on_input(Message::AtleastResolutionChanged)
                .padding(8)
                .style(crate::theme::text_input_style)
                .width(Length::Fill),
        );
    } else {
        resolution_controls = resolution_controls
            .push(text("Resolutions").size(12))
            .push(
                row![
                    checkbox(
                        "1920x1080",
                        filters
                            .resolutions
                            .iter()
                            .any(|r| r.width == 1920 && r.height == 1080)
                    )
                    .on_toggle(|b| Message::ToggleResolutionFilter(Resolution::new(1920, 1080), b)),
                    checkbox(
                        "2560x1440",
                        filters
                            .resolutions
                            .iter()
                            .any(|r| r.width == 2560 && r.height == 1440)
                    )
                    .on_toggle(|b| Message::ToggleResolutionFilter(Resolution::new(2560, 1440), b)),
                ]
                .spacing(8),
            )
            .push(
                row![
                    checkbox(
                        "3440x1440",
                        filters
                            .resolutions
                            .iter()
                            .any(|r| r.width == 3440 && r.height == 1440)
                    )
                    .on_toggle(|b| Message::ToggleResolutionFilter(Resolution::new(3440, 1440), b)),
                    checkbox(
                        "3840x2160",
                        filters
                            .resolutions
                            .iter()
                            .any(|r| r.width == 3840 && r.height == 2160)
                    )
                    .on_toggle(|b| Message::ToggleResolutionFilter(Resolution::new(3840, 2160), b)),
                ]
                .spacing(8),
            )
            .push(
                text_input("1920x1080, 2560x1440", app.resolution_filter_input())
                    .on_input(Message::ResolutionFilterChanged)
                    .padding(8)
                    .style(crate::theme::text_input_style)
                    .width(Length::Fill),
            );
    }

    let size_filters_section = container(
        column![
            text("Resolution & Ratio").size(15),
            resolution_controls,
            text("Ratios").size(12),
            row![
                checkbox(
                    "All Wide",
                    filters.ratios.iter().any(|ratio| ratio == "landscape")
                )
                .on_toggle(|b| Message::ToggleRatioFilter("landscape".to_string(), b)),
                checkbox(
                    "All Portrait",
                    filters.ratios.iter().any(|ratio| ratio == "portrait")
                )
                .on_toggle(|b| Message::ToggleRatioFilter("portrait".to_string(), b)),
            ]
            .spacing(8),
            row![
                checkbox("16x9", filters.ratios.iter().any(|ratio| ratio == "16x9"))
                    .on_toggle(|b| Message::ToggleRatioFilter("16x9".to_string(), b)),
                checkbox("16x10", filters.ratios.iter().any(|ratio| ratio == "16x10"))
                    .on_toggle(|b| Message::ToggleRatioFilter("16x10".to_string(), b)),
            ]
            .spacing(8),
            row![
                checkbox("21x9", filters.ratios.iter().any(|ratio| ratio == "21x9"))
                    .on_toggle(|b| Message::ToggleRatioFilter("21x9".to_string(), b)),
                checkbox("32x9", filters.ratios.iter().any(|ratio| ratio == "32x9"))
                    .on_toggle(|b| Message::ToggleRatioFilter("32x9".to_string(), b)),
            ]
            .spacing(8),
            row![
                checkbox("9x16", filters.ratios.iter().any(|ratio| ratio == "9x16"))
                    .on_toggle(|b| Message::ToggleRatioFilter("9x16".to_string(), b)),
                checkbox("10x16", filters.ratios.iter().any(|ratio| ratio == "10x16"))
                    .on_toggle(|b| Message::ToggleRatioFilter("10x16".to_string(), b)),
            ]
            .spacing(8),
            row![
                checkbox("1x1", filters.ratios.iter().any(|ratio| ratio == "1x1"))
                    .on_toggle(|b| Message::ToggleRatioFilter("1x1".to_string(), b)),
                checkbox("3x2", filters.ratios.iter().any(|ratio| ratio == "3x2"))
                    .on_toggle(|b| Message::ToggleRatioFilter("3x2".to_string(), b)),
            ]
            .spacing(8),
            row![
                checkbox("4x3", filters.ratios.iter().any(|ratio| ratio == "4x3"))
                    .on_toggle(|b| Message::ToggleRatioFilter("4x3".to_string(), b)),
                checkbox("5x4", filters.ratios.iter().any(|ratio| ratio == "5x4"))
                    .on_toggle(|b| Message::ToggleRatioFilter("5x4".to_string(), b)),
            ]
            .spacing(8),
            text_input("16x9, 21x9", app.ratio_filter_input())
                .on_input(Message::RatioFilterChanged)
                .padding(8)
                .style(crate::theme::text_input_style)
                .width(Length::Fill),
        ]
        .spacing(8),
    )
    .padding(12)
    .style(crate::theme::panel_subtle);

    let selected_color = filters.colors.first().map(|color| color.to_lowercase());
    let mut color_rows = column![].spacing(6);
    for row_colors in COLOR_PRESETS.chunks(6) {
        let mut color_row = row![].spacing(6);
        for color in row_colors {
            let label = format!("#{color}");
            let mut color_button = button(text(label).size(11))
                .on_press(Message::ColorFilterChanged((*color).to_string()))
                .width(Length::Fill)
                .padding(6);
            if selected_color.as_deref() == Some(*color) {
                color_button = color_button.style(crate::theme::button_primary);
            } else {
                color_button = color_button.style(crate::theme::button_secondary);
            }
            color_row = color_row.push(color_button);
        }
        color_rows = color_rows.push(color_row);
    }

    let color_section = container(
        column![
            text("Color").size(15),
            color_rows,
            row![
                text_input("#66cccc", app.color_filter_input())
                    .on_input(Message::ColorFilterChanged)
                    .padding(8)
                    .style(crate::theme::text_input_style)
                    .width(Length::Fill),
                button("Clear")
                    .on_press(Message::ColorFilterChanged(String::new()))
                    .style(crate::theme::button_secondary),
            ]
            .spacing(8)
            .align_y(Alignment::Center),
        ]
        .spacing(8),
    )
    .padding(12)
    .style(crate::theme::panel_subtle);

    let mut sidebar_content = column![
        text("Filters").size(20),
        text("Narrow down results quickly.").size(12),
        categories_section,
        purity_section,
        sorting_section,
        size_filters_section,
        color_section,
    ]
    .spacing(14)
    .width(Length::Fixed(240.0));

    if !app.related_tags().is_empty() {
        let mut related_tags_col = column![text("Related Tags").size(15)].spacing(8);

        for (tag, hits) in app.related_tags() {
            related_tags_col = related_tags_col.push(
                button(text(format!("#{tag} ({hits})")))
                    .on_press(Message::SearchByTag(tag.clone()))
                    .style(crate::theme::button_secondary)
                    .width(Length::Fill),
            );
        }

        sidebar_content = sidebar_content.push(
            container(related_tags_col)
                .padding(12)
                .style(crate::theme::panel_subtle),
        );
    }

    let sidebar = container(sidebar_content)
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

    let grid_options: Vec<u32> = vec![3, 4, 6];
    let current_cols = app.preferences().grid_columns;
    let sidebar_toggle_label = if app.is_search_sidebar_visible() {
        "Hide Filters"
    } else {
        "Show Filters"
    };

    let search_row = container(
        row![
            text_input(
                "Search... #tag/tag:name or @author/author:name",
                app.search_query(),
            )
            .on_input(Message::SearchQueryChanged)
            .on_submit(Message::SubmitSearch)
            .padding(10)
            .style(crate::theme::text_input_style)
            .width(Length::Fill),
            search_button,
            select_all_button,
            text(format!("Selected: {selected_count}")).size(13),
            button(sidebar_toggle_label)
                .on_press(Message::ToggleSearchSidebar)
                .style(crate::theme::button_secondary),
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
    .style(crate::theme::app_frame);

    let results_content = responsive(move |size| {
        let mut results_ctn = column![].spacing(12);

        if app.is_searching() && app.search_results().is_none() {
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
                return container(scrollable(results_ctn).height(Length::Fill))
                    .width(Length::Fill)
                    .height(Length::Fill)
                    .clip(true)
                    .into();
            }

            let available_width = if size.width <= 0.0 {
                900.0
            } else {
                size.width.max(1.0)
            };
            let spacing = 16.0;
            let min_item_width = 180.0;
            let desired = current_cols as usize;
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
            let item_width = ((available_width - total_spacing) / columns as f32).max(1.0);
            let thumbnail_height = (item_width * 0.62).clamp(100.0, 220.0);

            let mut grid_row = row![].spacing(spacing);
            let mut items_in_row = 0;

            for wp in &results.wallpapers {
                let thumbnail: Element<'_, Message> =
                    if let Some(handle) = app.get_thumbnail(&wp.id) {
                        image(handle)
                            .width(Length::Fill)
                            .height(Length::Fixed(thumbnail_height))
                            .content_fit(iced::ContentFit::Contain)
                            .into()
                    } else {
                        container(text("Loading preview..."))
                            .width(Length::Fill)
                            .height(Length::Fixed(thumbnail_height))
                            .align_x(iced::alignment::Horizontal::Center)
                            .align_y(iced::alignment::Vertical::Center)
                            .into()
                    };

                let tile_click_id = wp.id.clone();
                let is_selected = app.selected_wallpapers().contains(&wp.id);

                let non_image_area = mouse_area(
                    column![
                        text(format!(
                            "{}x{} | Fav {} | Views {}",
                            wp.resolution.width, wp.resolution.height, wp.favorites, wp.views
                        ))
                        .size(12)
                        .wrapping(TextWrapping::None),
                        column![
                            button("Set")
                                .on_press(Message::QuickSet(wp.clone()))
                                .style(crate::theme::button_secondary)
                                .width(Length::Fill),
                            button("Bookmark")
                                .on_press(Message::AddBookmark(wp.clone()))
                                .style(crate::theme::button_secondary)
                                .width(Length::Fill),
                        ]
                        .spacing(8)
                        .width(Length::Fill),
                    ]
                    .spacing(8),
                )
                .on_press(Message::TileClicked(tile_click_id));

                let thumbnail_region = container(thumbnail)
                    .width(Length::Fill)
                    .height(Length::Fixed(thumbnail_height))
                    .clip(true);

                let item = container(
                    column![
                        mouse_area(
                            container(thumbnail_region)
                                .width(Length::Fill)
                                .height(Length::Fixed(thumbnail_height))
                                .clip(true),
                        )
                        .on_press(Message::SwitchView(crate::app::View::Preview(wp.clone()))),
                        container(non_image_area).width(Length::Fill),
                    ]
                    .spacing(8),
                )
                .padding(10)
                .width(Length::Fixed(item_width))
                .clip(true)
                .style(if is_selected {
                    crate::theme::panel_selected
                } else {
                    match wp.purity {
                        Purity::Nsfw => crate::theme::panel_nsfw,
                        Purity::Sketchy => crate::theme::panel_sketchy,
                        _ => crate::theme::panel_subtle,
                    }
                });

                grid_row = grid_row.push(item);
                items_in_row += 1;

                if items_in_row == columns {
                    results_ctn = results_ctn.push(grid_row);
                    grid_row = row![].spacing(spacing);
                    items_in_row = 0;
                }
            }

            if items_in_row > 0 {
                results_ctn = results_ctn.push(grid_row);
            }

            if app.is_loading_more_search_results() {
                results_ctn = results_ctn.push(
                    container(
                        row![
                            text("Loading more wallpapers").size(14),
                            text("...").size(14),
                        ]
                        .spacing(8)
                        .align_y(Alignment::Center),
                    )
                    .padding(10)
                    .style(crate::theme::panel_subtle),
                );
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

        let results_scroll = scrollable(results_ctn)
            .id(scrollable::Id::new(SEARCH_SCROLL_ID))
            .width(Length::Fill)
            .height(Length::Fill)
            .on_scroll(Message::SearchScrolled);
        container(results_scroll)
            .width(Length::Fill)
            .height(Length::Fill)
            .clip(true)
            .into()
    });

    let mut main_content = column![search_row]
        .spacing(14)
        .width(Length::Fill)
        .height(Length::Fill);
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
                    button("Bookmark Selected")
                        .on_press(Message::BookmarkSelected)
                        .style(crate::theme::button_secondary),
                ]
                .spacing(10)
                .align_y(Alignment::Center),
            )
            .padding(10)
            .style(crate::theme::app_frame),
        );
    }
    main_content = main_content.push(
        container(results_content)
            .width(Length::Fill)
            .height(Length::Fill)
            .clip(true),
    );

    if app.is_search_sidebar_visible() {
        container(
            row![sidebar, main_content]
                .spacing(18)
                .width(Length::Fill)
                .height(Length::Fill),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .clip(true)
        .into()
    } else {
        container(main_content)
            .width(Length::Fill)
            .height(Length::Fill)
            .clip(true)
            .into()
    }
}
