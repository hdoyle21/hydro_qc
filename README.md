# hydroquebec-tracker

Automatically collects Hydro-Québec outage and planned interruption data every 15 minutes via GitHub Actions and archives it as CSV files in this repo.

## Data

| Folder | Contents |
|---|---|
| `data/outages/` | One CSV per day of current outage snapshots |
| `data/planned/` | One CSV per day of planned interruption snapshots |

Each file is named `YYYY-MM-DD.csv` (UTC). Rows are appended each run, deduplicated by BIS/AIP version so you don't get duplicate snapshots if the API hasn't updated.

### Outage columns

| Column | Description |
|---|---|
| `customers_affected` | Number of customers without power |
| `start_time` | Outage start (local time as returned by API) |
| `estimated_end_time` | Estimated restoration time |
| `type` | Interruption or Outage |
| `longitude` / `latitude` | Location of affected area |
| `status` | Crew status (Work assigned / Crew at work / Crew en route) |
| `cause` | Decoded cause category |
| `cause_code` | Raw cause code from API |
| `municipality_id` | Municipality identifier |
| `bis_version` | API snapshot version (timestamp) |
| `pulled_at` | When this row was collected (UTC) |

### Planned interruption columns

| Column | Description |
|---|---|
| `customers_affected` | Number of affected customers |
| `notice_id` | Planned interruption notice ID |
| `planned_start` / `planned_end` | Scheduled window |
| `actual_start` / `actual_end` | Actual times if available |
| `longitude` / `latitude` | Location |
| `aip_version` | API snapshot version |
| `pulled_at` | When this row was collected (UTC) |

## Loading data in R

```r
library(readr)
library(dplyr)

# Load all outage history
outages <- list.files("data/outages", full.names = TRUE) |>
  lapply(read_csv, show_col_types = FALSE) |>
  bind_rows()

# Load a specific date
today <- read_csv("data/outages/2026-05-07.csv")
```
