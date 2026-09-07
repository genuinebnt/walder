//! Turning command-line flags into a search.
//!
//! One set of flags, shared by every command that searches — `search`,
//! `download --search`, `random --source search` — so a filter that works in
//! one works in all of them.

use clap::Args;
use lumen_core::*;

#[derive(Args, Debug, Clone, Default)]
pub struct SearchArgs {
    /// Search terms. Wallhaven operators work here: `#tag` for a tag,
    /// `@user` for an uploader, `like:ID` for similar wallpapers, `-word` to
    /// exclude, `type:png` for a file type.
    ///
    /// A flag rather than a positional because `download` and `random` already
    /// take positional arguments of their own; `search` accepts it either way.
    #[arg(short = 'q', long)]
    pub query: Option<String>,

    /// Categories to include: general, anime, people.
    #[arg(short, long, value_delimiter = ',', default_values = ["general", "anime"])]
    pub category: Vec<String>,

    /// Purity to include: sfw, sketchy, nsfw. Anything but sfw needs an API key.
    #[arg(short, long, value_delimiter = ',', default_values = ["sfw"])]
    pub purity: Vec<String>,

    /// date_added, relevance, random, views, favorites, toplist, hot.
    #[arg(short, long, default_value = "date_added")]
    pub sort: String,

    /// asc or desc.
    #[arg(long, default_value = "desc")]
    pub order: String,

    /// Window for toplist sorting: 1d, 3d, 1w, 1M, 3M, 6M, 1y.
    #[arg(long)]
    pub top_range: Option<String>,

    /// Minimum resolution, e.g. 2560x1440.
    #[arg(long, value_name = "WxH")]
    pub atleast: Option<String>,

    /// Exact resolutions, repeatable, e.g. --resolution 3840x2160.
    #[arg(long, value_name = "WxH")]
    pub resolution: Vec<String>,

    /// Aspect ratios, repeatable, e.g. --ratio 16x9.
    #[arg(long, value_name = "WxH")]
    pub ratio: Vec<String>,

    /// Dominant colour as hex. Wallhaven accepts one.
    #[arg(long, value_name = "RRGGBB")]
    pub color: Option<String>,

    /// Show only AI art.
    #[arg(long, conflicts_with = "no_ai_art")]
    pub ai_art: bool,

    /// Hide AI art.
    #[arg(long)]
    pub no_ai_art: bool,

    /// First page to fetch.
    #[arg(long, default_value_t = 1)]
    pub page: u32,
}

impl SearchArgs {
    pub fn to_filters(&self) -> anyhow::Result<SearchFilters> {
        let categories = parse_list(&self.category, "category", |value| match value {
            "general" => Some(Category::General),
            "anime" => Some(Category::Anime),
            "people" => Some(Category::People),
            _ => None,
        })?;

        let purity = parse_list(&self.purity, "purity", |value| match value {
            "sfw" => Some(Purity::Sfw),
            "sketchy" => Some(Purity::Sketchy),
            "nsfw" => Some(Purity::Nsfw),
            _ => None,
        })?;

        let sorting = match self.sort.to_lowercase().as_str() {
            "date_added" | "date" | "latest" => Sorting::DateAdded,
            "relevance" => Sorting::Relevance,
            "random" => Sorting::Random,
            "views" => Sorting::Views,
            "favorites" | "favourites" => Sorting::Favorites,
            "toplist" | "top" => Sorting::Toplist,
            "hot" => Sorting::Hot,
            other => anyhow::bail!("unknown sort \"{other}\""),
        };

        let order = match self.order.to_lowercase().as_str() {
            "desc" | "descending" => SortOrder::Desc,
            "asc" | "ascending" => SortOrder::Asc,
            other => anyhow::bail!("unknown order \"{other}\""),
        };

        let toplist_range = match self.top_range.as_deref() {
            None => None,
            Some("1d") => Some(ToplistRange::OneDay),
            Some("3d") => Some(ToplistRange::ThreeDays),
            Some("1w") => Some(ToplistRange::OneWeek),
            Some("1M") => Some(ToplistRange::OneMonth),
            Some("3M") => Some(ToplistRange::ThreeMonths),
            Some("6M") => Some(ToplistRange::SixMonths),
            Some("1y") => Some(ToplistRange::OneYear),
            Some(other) => anyhow::bail!("unknown top range \"{other}\""),
        };

        let atleast = match &self.atleast {
            Some(value) => Some(parse_resolution(value)?),
            None => None,
        };
        let resolutions = self
            .resolution
            .iter()
            .map(|value| parse_resolution(value))
            .collect::<anyhow::Result<Vec<_>>>()?;

        let ai_art_filter = if self.ai_art {
            Some(true)
        } else if self.no_ai_art {
            Some(false)
        } else {
            None
        };

        Ok(SearchFilters {
            // The query is passed through untouched: stripping the `#` off a
            // tag search turns it into a keyword search, which is a different
            // and much worse result set.
            query: self.query.clone().filter(|q| !q.trim().is_empty()),
            categories,
            purity,
            sorting,
            order,
            toplist_range,
            atleast,
            resolutions,
            ratios: self.ratio.clone(),
            // Wallhaven wants hex without the `#`.
            colors: self
                .color
                .iter()
                .map(|c| c.trim_start_matches('#').to_string())
                .collect(),
            page: self.page.max(1),
            seed: None,
            ai_art_filter,
        })
    }
}

fn parse_list<T>(
    values: &[String],
    what: &str,
    parse: impl Fn(&str) -> Option<T>,
) -> anyhow::Result<Vec<T>> {
    values
        .iter()
        .map(|value| {
            parse(value.trim().to_lowercase().as_str())
                .ok_or_else(|| anyhow::anyhow!("unknown {what} \"{value}\""))
        })
        .collect()
}

pub fn parse_resolution(value: &str) -> anyhow::Result<Resolution> {
    let (width, height) = value
        .split_once(['x', 'X', '×'])
        .ok_or_else(|| anyhow::anyhow!("resolution should look like 1920x1080, got \"{value}\""))?;
    Ok(Resolution::new(
        width.trim().parse()?,
        height.trim().parse()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args() -> SearchArgs {
        SearchArgs {
            category: vec!["general".into()],
            purity: vec!["sfw".into()],
            sort: "date_added".into(),
            order: "desc".into(),
            page: 1,
            ..Default::default()
        }
    }

    #[test]
    fn a_tag_query_keeps_its_hash() {
        let mut a = args();
        a.query = Some("#landscape".into());
        assert_eq!(a.to_filters().unwrap().query.unwrap(), "#landscape");
    }

    #[test]
    fn a_colour_loses_its_hash() {
        let mut a = args();
        a.color = Some("#663399".into());
        assert_eq!(a.to_filters().unwrap().colors, vec!["663399".to_string()]);
    }

    #[test]
    fn resolutions_parse_either_separator() {
        assert_eq!(parse_resolution("1920x1080").unwrap(), Resolution::new(1920, 1080));
        assert_eq!(parse_resolution("3840X2160").unwrap(), Resolution::new(3840, 2160));
        assert!(parse_resolution("wide").is_err());
    }

    #[test]
    fn an_unknown_category_is_an_error_not_a_silent_default() {
        let mut a = args();
        a.category = vec!["nature".into()];
        assert!(a.to_filters().is_err());
    }

    #[test]
    fn ai_art_is_three_states() {
        assert_eq!(args().to_filters().unwrap().ai_art_filter, None);
        let mut only = args();
        only.ai_art = true;
        assert_eq!(only.to_filters().unwrap().ai_art_filter, Some(true));
        let mut without = args();
        without.no_ai_art = true;
        assert_eq!(without.to_filters().unwrap().ai_art_filter, Some(false));
    }

    #[test]
    fn an_empty_query_is_no_query() {
        let mut a = args();
        a.query = Some("   ".into());
        assert!(a.to_filters().unwrap().query.is_none());
    }
}
