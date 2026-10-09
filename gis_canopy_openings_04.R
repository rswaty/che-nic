
# Notes ----
## Canopy openings from LANDFIRE canopy cover and annual disturbance
## downloads LF2016/LF2024 canopy cover and 2021-2025 annual disturbance
## run after gis_conifer_bps_03.R
## code by Randy Swaty


# Set up ----

library(exactextractr)
library(rlandfire)
library(sf)
library(terra)
library(tidyverse)

source("gis_smooth_helpers.R")

## smoothing knobs: openings are small, so stay at 30 m with a light blur
agg_fact    <- 1
sigma_m     <- 30
share_cut   <- 0.5
min_acres   <- 5
min_hole_ac <- 5
simplify_m  <- 10

cover_cut     <- 50    # "open" = LF2024 canopy cover below this
drop_fraction <- 0.5   # "cover drop" = LF2016 cover cut by at least this fraction

def_open <- "Disturbed 2021-2024, cover now < 50%"
def_drop <- "Cover drop >= 50% (2016 to 2024)"
def_2025 <- "Disturbed 2025, cover not yet updated"

## BpS groups that can support forest; open wetlands, water, barren and grassland excluded
forest_groupveg  <- c("Hardwood", "Conifer", "Hardwood-Conifer", "Riparian")
nonforest_bps    <- 14940  # Laurentian-Acadian Shrub-Herbaceous Wetland Systems

shp <- st_read("inputs/cnnf.shp", quiet = TRUE) |>
  st_transform(crs = 5070) |>
  st_make_valid() |>
  st_union() |>
  st_sf()


# Download LANDFIRE canopy cover and disturbance ----
# skip download if already present (saves a long API round-trip)

openings_products <- c("LF2016_CC", "LF2024_CC",
                       "LF2022_Dist21", "LF2022_Dist22", "LF2023_Dist23",
                       "LF2024_Dist24", "LF2025_Dist25")

if (!file.exists("inputs/landfire_openings.tif")) {
  save_file <- tempfile(fileext = ".zip")

  landfireAPIv2(
    products   = openings_products,
    aoi        = getAOI(shp),
    projection = 5070,
    resolution = 30,
    path       = save_file,
    email      = "rswaty@tnc.org" # REPLACE WITH YOUR E-MAIL ADDRESS PLEASE!
  )

  file.copy(save_file, "inputs/landfire_openings.zip", overwrite = TRUE)

  temp_dir <- tempfile()
  dir.create(temp_dir)
  unzip("inputs/landfire_openings.zip", exdir = temp_dir)

  for (file in list.files(temp_dir, full.names = TRUE)) {
    file_extension <- sub("^[^.]*", "", basename(file))
    file.copy(file, file.path("inputs", paste0("landfire_openings", file_extension)),
              overwrite = TRUE)
  }

  unlink(temp_dir, recursive = TRUE)
} else {
  message("Using existing inputs/landfire_openings.tif")
}


# Load and align layers ----

bps <- rast("outputs/bps_aoi.tif")
levels(bps) <- NULL

bps_atts <- read_csv("outputs/bps_aoi_attributes.csv", show_col_types = FALSE)

lf <- rast("inputs/landfire_openings.tif") |>
  crop(bps) |>
  mask(bps)

layer_for <- function(pattern) lf[[grep(pattern, names(lf))]]

cc_2016 <- layer_for("LF2016_CC")
cc_2024 <- layer_for("LF2024_CC")

forest_values <- bps_atts |>
  filter(GROUPVEG %in% forest_groupveg, !BPS_CODE %in% nonforest_bps) |>
  pull(VALUE)

forest_ok <- classify(bps, cbind(forest_values, 1), others = 0) |>
  mask(bps)


# Disturbance by year ----

dist_years <- 2021:2025

dist_luts <- map(dist_years, function(y) {
  list.files("inputs/dist_csv", pattern = sprintf("Dist%02d", y %% 100), full.names = TRUE) |>
    read_csv(show_col_types = FALSE) |>
    rename_with(~ sub("^\ufeff", "", .x)) |>
    select(VALUE, DIST_TYPE) |>
    filter(VALUE > 0, !is.na(DIST_TYPE), DIST_TYPE != "Water")
}) |>
  set_names(dist_years)

dist_types <- tibble(DIST_TYPE = sort(unique(unlist(map(dist_luts, "DIST_TYPE"))))) |>
  mutate(type_id = row_number())

## per year: disturbance type id where disturbed, NA elsewhere
dist_type_by_year <- map(dist_years, function(y) {
  rcl <- dist_luts[[as.character(y)]] |>
    left_join(dist_types, by = "DIST_TYPE") |>
    select(VALUE, type_id) |>
    as.matrix()
  classify(layer_for(sprintf("Dist%02d", y %% 100)), rcl, others = NA)
}) |>
  set_names(dist_years)

## most recent 2021-2024 disturbance wins
recent_years <- as.character(2024:2021)

latest_type <- Reduce(cover, dist_type_by_year[recent_years])
latest_year <- Reduce(cover, map(recent_years, function(y) {
  ifel(is.na(dist_type_by_year[[y]]), NA, as.integer(y))
}))

type_2025 <- dist_type_by_year[["2025"]]

any_dist <- ifel(is.na(latest_year) & is.na(type_2025), 0, 1) |>
  mask(bps)


# Opening masks ----

mask_open <- ifel(!is.na(latest_year) & cc_2024 < cover_cut & forest_ok == 1, 1, 0) |>
  mask(bps)

mask_drop <- ifel(cc_2016 > 0 & (cc_2016 - cc_2024) >= drop_fraction * cc_2016 &
                    forest_ok == 1, 1, 0) |>
  mask(bps)

mask_2025 <- ifel(!is.na(type_2025) & forest_ok == 1, 1, 0) |>
  mask(bps)

opening_masks <- list(mask_open, mask_drop, mask_2025) |>
  set_names(c(def_open, def_drop, def_2025))

pixel_acres <- map_dbl(opening_masks, ~ global(.x, "sum", na.rm = TRUE)[[1]] * 900 / m2_per_acre)
print(round(pixel_acres))


# Smooth to polygons ----

openings <- imap(opening_masks, function(m, def) {
  smooth_mask(m, shp, agg_fact = agg_fact, sigma_m = sigma_m, share_cut = share_cut,
              min_hole_ac = min_hole_ac, simplify_m = simplify_m) |>
    mutate(definition = def, .before = 1)
}) |>
  bind_rows() |>
  mutate(acres = as.numeric(st_area(geometry)) / m2_per_acre) |>
  filter(acres >= min_acres)


# Attributes ----

weighted_mode <- function(x, w) {
  ok <- !is.na(x)
  if (!any(ok)) return(NA_real_)
  totals <- tapply(w[ok], x[ok], sum)
  as.numeric(names(totals)[which.max(totals)])
}

weighted_mean <- function(x, w) {
  ok <- !is.na(x)
  if (!any(ok)) return(NA_real_)
  sum(x[ok] * w[ok]) / sum(w[ok])
}

att_stack <- c(latest_year, latest_type, type_2025, cc_2016, cc_2024, any_dist)
names(att_stack) <- c("latest_year", "latest_type", "type_2025", "cc_2016", "cc_2024", "any_dist")

opening_atts <- exact_extract(
  att_stack, openings, progress = FALSE, summarize_df = TRUE,
  fun = function(df) {
    w <- df$coverage_fraction
    data.frame(
      dist_year_recent = weighted_mode(df$latest_year, w),
      type_id_recent   = weighted_mode(df$latest_type, w),
      type_id_2025     = weighted_mode(df$type_2025, w),
      cc_2016          = round(weighted_mean(df$cc_2016, w)),
      cc_2024          = round(weighted_mean(df$cc_2024, w)),
      pct_disturbed    = round(100 * weighted_mean(df$any_dist, w))
    )
  }
)

conifer_polys <- st_read("outputs/conifer_bps_smooth.gpkg", quiet = TRUE) |>
  select(conifer_group = group)

openings <- openings |>
  bind_cols(opening_atts) |>
  mutate(
    dist_year = if_else(definition == def_2025, 2025, dist_year_recent),
    type_id   = if_else(definition == def_2025, type_id_2025, type_id_recent)
  ) |>
  left_join(dist_types, by = "type_id") |>
  st_join(conifer_polys, join = st_intersects, largest = TRUE) |>
  mutate(
    conifer_group = replace_na(conifer_group, "Outside conifer BpS"),
    acres         = round(acres, 1),
    drop_pts      = cc_2016 - cc_2024,
    opening_id    = row_number()
  ) |>
  select(opening_id, definition, conifer_group, dist_year, dist_type = DIST_TYPE,
         cc_2016, cc_2024, drop_pts, pct_disturbed, acres)


# Summaries and outputs ----

openings_summary <- openings |>
  st_drop_geometry() |>
  group_by(definition, conifer_group) |>
  summarize(n_openings = n(), acres = round(sum(acres)), .groups = "drop")

print(openings_summary, n = Inf)

openings |>
  st_drop_geometry() |>
  group_by(definition) |>
  summarize(n_openings = n(),
            pct_with_2021_2025_disturbance = round(weighted.mean(pct_disturbed, acres)),
            acres = round(sum(acres))) |>
  print()

cat(sprintf("Total vertices: %s\n",
            format(nrow(st_coordinates(openings)), big.mark = ",")))

unlink("outputs/canopy_openings.gpkg")
st_write(openings, "outputs/canopy_openings.gpkg", quiet = TRUE)

write_csv(openings_summary, "outputs/canopy_openings_summary.csv")
