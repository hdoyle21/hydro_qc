# ============================================================
# Hydro-Québec — Outage Archiver
# Called by GitHub Actions every 15 minutes.
# Appends a timestamped CSV to data/outages/ and data/planned/
# ============================================================

library(httr)
library(jsonlite)
library(dplyr)
library(tibble)
library(purrr)
library(readr)

BASE_URL <- "https://pannes.hydroquebec.com/pannes/donnees/v3_0"

CAUSE_CODES <- tribble(
  ~code,    ~cause,
  "11", "Equipment failure", "12", "Equipment failure", "13", "Equipment failure",
  "14", "Equipment failure", "15", "Equipment failure", "58", "Equipment failure",
  "70", "Equipment failure", "72", "Equipment failure", "73", "Equipment failure",
  "74", "Equipment failure", "79", "Equipment failure",
  "21", "Weather conditions", "22", "Weather conditions", "24", "Weather conditions",
  "25", "Weather conditions", "26", "Weather conditions",
  "31", "Accident or incident", "32", "Accident or incident", "33", "Accident or incident",
  "34", "Accident or incident", "41", "Accident or incident", "42", "Accident or incident",
  "43", "Accident or incident", "44", "Accident or incident", "54", "Accident or incident",
  "55", "Accident or incident", "56", "Accident or incident", "57", "Accident or incident",
  "51", "Vegetation damage",
  "52", "Animal damage", "53", "Animal damage",
  "defaut", "Equipment failure"
)

STATUS_CODES <- c(A = "Work assigned", L = "Crew at work",  R = "Crew en route")
TYPE_LABELS  <- c(I = "Interruption",  P = "Outage")

# ── Helpers ───────────────────────────────────────────────────

get_version <- function(endpoint) {
  resp <- GET(paste0(BASE_URL, "/", endpoint))
  stop_for_status(resp)
  content(resp, as = "text", encoding = "UTF-8") |> fromJSON() |> unlist() |> as.character()
}

get_raw_text <- function(endpoint) {
  resp <- GET(paste0(BASE_URL, "/", endpoint))
  stop_for_status(resp)
  content(resp, as = "text", encoding = "UTF-8")
}

decode_cause <- function(code) {
  code <- as.character(code)
  matched <- CAUSE_CODES$cause[CAUSE_CODES$code == code]
  if (length(matched) > 0) return(matched[1])
  n <- suppressWarnings(as.integer(code))
  if (!is.na(n)) {
    if (n %in% c(11:15, 58, 70, 72:74, 79)) return("Equipment failure")
    if (n %in% c(21, 22, 24:26))             return("Weather conditions")
    if (n %in% c(31:34, 41:44, 54:57))       return("Accident or incident")
    if (n == 51)                              return("Vegetation damage")
    if (n %in% c(52, 53))                     return("Animal damage")
  }
  NA_character_
}

safe_get <- function(x, i, default = NA) {
  v <- tryCatch(x[[i]], error = function(e) default)
  if (is.null(v)) default else v
}

parse_coords <- function(x) {
  tryCatch({
    v <- fromJSON(as.character(x))
    list(lon = as.numeric(v[1]), lat = as.numeric(v[2]))
  }, error = function(e) list(lon = NA_real_, lat = NA_real_))
}

# ── Fetch ─────────────────────────────────────────────────────

fetch_current_outages <- function() {
  version  <- get_version("bisversion.json")
  raw_text <- get_raw_text(paste0("bismarkers", version, ".json"))
  parsed   <- fromJSON(raw_text, simplifyVector = FALSE)
  pannes   <- parsed$pannes
  if (is.null(pannes) || length(pannes) == 0) {
    message("No current outages.")
    return(tibble())
  }

  rows <- map(pannes, function(p) {
    coords <- parse_coords(safe_get(p, 5, "[]"))
    tibble(
      customers_affected = as.integer(safe_get(p, 1)),
      start_time         = as.character(safe_get(p, 2)),
      estimated_end_time = as.character(safe_get(p, 3)),
      type_code          = as.character(safe_get(p, 4)),
      type               = unname(TYPE_LABELS[as.character(safe_get(p, 4))]),
      longitude          = coords$lon,
      latitude           = coords$lat,
      status_code        = as.character(safe_get(p, 6)),
      status             = unname(STATUS_CODES[as.character(safe_get(p, 6))]),
      cause_code         = as.character(safe_get(p, 8)),
      cause              = decode_cause(safe_get(p, 8)),
      municipality_id    = as.character(safe_get(p, 9)),
      message_id         = as.character(safe_get(p, 10))
    )
  })

  result <- bind_rows(rows)
  result$bis_version <- version
  result$pulled_at   <- format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")
  result
}

fetch_planned_interruptions <- function() {
  version  <- get_version("aipversion.json")
  raw_text <- get_raw_text(paste0("aipmarkers", version, ".json"))
  parsed   <- fromJSON(raw_text, simplifyVector = FALSE)
  aips     <- parsed$aips %||% parsed$interruptions %||% parsed$pannes %||% parsed[[1]]
  if (is.null(aips) || length(aips) == 0) {
    message("No planned interruptions.")
    return(tibble())
  }

  rows <- map(aips, function(p) {
    coords_idx <- which(sapply(p, function(x) grepl("^\\[", as.character(x))))
    coords <- if (length(coords_idx) > 0) parse_coords(p[[coords_idx[1]]]) else list(lon = NA_real_, lat = NA_real_)
    tibble(
      customers_affected = as.integer(safe_get(p, 1)),
      notice_id          = as.character(safe_get(p, 2)),
      planned_start      = as.character(safe_get(p, 3)),
      planned_end        = as.character(safe_get(p, 4)),
      actual_start       = as.character(safe_get(p, 5)),
      actual_end         = as.character(safe_get(p, 6)),
      longitude          = coords$lon,
      latitude           = coords$lat
    )
  })

  result <- bind_rows(rows)
  result$aip_version <- version
  result$pulled_at   <- format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")
  result
}

# ── Save ──────────────────────────────────────────────────────

# One CSV per day — each run appends rows to today's file.
# This keeps file count low while still being queryable by date.

stamp     <- format(Sys.time(), "%Y-%m-%d", tz = "UTC")
out_dir   <- "data/outages"
plan_dir  <- "data/planned"
dir.create(out_dir,  showWarnings = FALSE, recursive = TRUE)
dir.create(plan_dir, showWarnings = FALSE, recursive = TRUE)

out_file  <- file.path(out_dir,  paste0(stamp, ".csv"))
plan_file <- file.path(plan_dir, paste0(stamp, ".csv"))

save_snapshot <- function(df, path) {
  if (nrow(df) == 0) return(invisible(NULL))
  if (file.exists(path)) {
    # Avoid duplicate snapshots if the BIS version hasn't changed
    existing <- read_csv(path, show_col_types = FALSE)
    version_col <- intersect(c("bis_version", "aip_version"), names(df))
    if (length(version_col) > 0 && df[[version_col]][1] %in% existing[[version_col]]) {
      message("Version already recorded, skipping: ", df[[version_col]][1])
      return(invisible(NULL))
    }
    write_csv(df, path, append = TRUE, col_names = FALSE)
  } else {
    write_csv(df, path)
  }
  message("Saved ", nrow(df), " rows to ", path)
}

outages <- fetch_current_outages()
planned <- fetch_planned_interruptions()

save_snapshot(outages, out_file)
save_snapshot(planned, plan_file)
