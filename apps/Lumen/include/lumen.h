// Bridging header for the Rust core (crates/lumen-ffi).
//
// Async calls return a request id immediately and deliver a JSON envelope to
// the callback registered with lumen_set_callback. Unsolicited pushes (download
// progress) arrive with request id 0.
//
// Every char* returned by this library must be released with lumen_string_free.

#ifndef LUMEN_H
#define LUMEN_H

#include <stdint.h>

typedef void (*LumenCallback)(uint64_t request_id, const char *json, void *ctx);

// Lifecycle
char *lumen_init(const char *config_json);
void  lumen_set_callback(LumenCallback callback, void *ctx);
char *lumen_status(void);
void  lumen_string_free(char *ptr);

// Search
uint64_t lumen_search(const char *filters_json);
uint64_t lumen_details(const char *id);

// Uploader and tags
uint64_t lumen_uploader_collections(const char *username);
uint64_t lumen_uploader_collection_wallpapers(const char *json);
uint64_t lumen_tag_info(uint64_t tag_id);

// Downloads
uint64_t lumen_download(const char *json);
uint64_t lumen_downloads_clear_finished(void);
char    *lumen_downloads_snapshot(void);
uint64_t lumen_ensure_local(const char *json);

// Favorites
char *lumen_favorites_list(void);
char *lumen_favorite_toggle(const char *wallpaper_json);

// Collections
char *lumen_collections_list(void);
char *lumen_collection_create(const char *name);
char *lumen_collection_delete(const char *id);
char *lumen_collection_set_member(const char *json);

// Bulk actions
char    *lumen_favorites_set_many(const char *json);
char    *lumen_collection_add_many(const char *json);
uint64_t lumen_download_many(const char *json);

// Preferences
char *lumen_set_preferences(const char *json);
char *lumen_download_dir(void);

#endif
