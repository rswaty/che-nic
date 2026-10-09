
# Notes ----
## Smoothed (rounded) polygons of conifer-associated BpSs for interactive mapping
## approach: per-group share at 90 m -> Gaussian blur -> contour (isoband)
## overlaps between groups are resolved so each acre belongs to one group
## writes outputs/conifer_bps_smooth.gpkg (EPSG:5070), a summary csv and a review jpg
## run after gis_clip_make_atts_02.R (needs outputs/bps_aoi.tif)
## code by Randy Swaty


# Set up ----

library(exactextractr)
library(gridExtra)
library(sf)
library(terra)
library(tidyverse)

source("gis_smooth_helpers.R")

## tuning knobs
agg_fact    <- 3     # 30 m -> 90 m before smoothing
sigma_m     <- 100   # Gaussian sigma in meters; larger = rounder / less detail
share_cut   <- 0.4   # contour level: neighborhood share of the group
min_acres   <- 20    # drop polygons smaller than this
min_hole_ac <- 40    # fill holes smaller than this
simplify_m  <- 15    # vertex thinning tolerance in meters

## priority decides which group keeps an overlap (1 wins); rarer conifer types first
## colors are Okabe-Ito (colorblind safe); vermillion #D55E00, orange #E69F00
## and black are left unused so canopy openings stand out on top
conifer_groups <- tribble(
  ~group,                       ~priority, ~color,
  "Spruce-fir",                 1,         "#0072B2",
  "Jack pine barrens",          2,         "#F0E442",
  "Pine-hemlock-hardwood",      3,         "#56B4E9",
  "Pine (red/white)",           4,         "#009E73",
  "Northern hardwoods-hemlock", 5,         "#CC79A7"
)

conifer_bps <- tribble(
  ~BPS_CODE, ~group,
  13651,     "Spruce-fir",
  13652,     "Spruce-fir",
  13653,     "Spruce-fir",
  14072,     "Jack pine barrens",
  14071,     "Jack pine barrens",
  13440,     "Jack pine barrens",
  13660,     "Pine-hemlock-hardwood",
  13622,     "Pine (red/white)",
  13022,     "Northern hardwoods-hemlock"
)

group_colors <- deframe(select(conifer_groups, group, color))
group_levels <- conifer_groups$group[order(conifer_groups$priority)]

shp <- st_read("inputs/cnnf.shp", quiet = TRUE) |>
  st_transform(5070) |>
  st_make_valid() |>
  st_union() |>
  st_sf()

bps <- rast("outputs/bps_aoi.tif")
levels(bps) <- NULL

bps_atts <- read_csv("outputs/bps_aoi_attributes.csv", show_col_types = FALSE)

bps_lut <- bps_atts |>
  distinct(VALUE, BPS_CODE, BPS_MODEL, BPS_NAME)


# Helpers ----

smooth_group <- function(codes, group_name) {
  values_in_group <- bps_lut$VALUE[bps_lut$BPS_CODE %in% codes]

  in_group <- classify(bps, cbind(values_in_group, 1), others = 0) |>
    mask(bps)

  smooth_mask(in_group, shp, agg_fact = agg_fact, sigma_m = sigma_m,
              share_cut = share_cut, min_hole_ac = min_hole_ac,
              simplify_m = simplify_m) |>
    mutate(group = group_name, .before = 1)
}


# Build polygons ----

raw_polys <- conifer_bps |>
  group_by(group) |>
  group_map(~ smooth_group(.x$BPS_CODE, .y$group)) |>
  set_names(sort(unique(conifer_bps$group)))

## resolve overlaps: higher-priority groups claim shared area first
claimed       <- NULL
conifer_polys <- list()

for (g in group_levels) {
  polys <- raw_polys[[g]]
  if (!is.null(claimed)) {
    polys <- st_difference(polys, claimed) |> as_polygons()
  }
  conifer_polys[[g]] <- polys
  claimed <- if (is.null(claimed)) st_union(polys) else st_union(c(claimed, st_union(polys)))
}

conifer_polys <- bind_rows(conifer_polys) |>
  st_make_valid() |>
  as_polygons() |>
  mutate(acres = as.numeric(st_area(geometry)) / m2_per_acre) |>
  filter(acres >= min_acres)


# Attributes ----

## share of each BpS value inside every polygon
bps_frac <- exact_extract(bps, conifer_polys, "frac", progress = FALSE) |>
  mutate(row = row_number()) |>
  pivot_longer(-row, names_to = "VALUE", values_to = "frac",
               names_transform = list(VALUE = ~ as.integer(sub("frac_", "", .x)))) |>
  left_join(bps_lut, by = "VALUE") |>
  left_join(rename(conifer_bps, bps_group = group), by = "BPS_CODE")

## pct_group = share of the polygon mapped as one of its group's BpSs;
## bps_model / bps_name = the most common of those BpSs
poly_atts <- bps_frac |>
  mutate(poly_group = conifer_polys$group[row]) |>
  filter(bps_group == poly_group) |>
  group_by(row, BPS_MODEL, BPS_NAME) |>
  summarize(frac = sum(frac), .groups = "drop") |>
  group_by(row) |>
  summarize(
    pct_group = round(100 * sum(frac)),
    bps_model = BPS_MODEL[which.max(frac)],
    bps_name  = BPS_NAME[which.max(frac)]
  )

conifer_polys <- conifer_polys |>
  mutate(row = row_number()) |>
  left_join(poly_atts, by = "row") |>
  mutate(
    group     = factor(group, levels = group_levels),
    color     = unname(group_colors[as.character(group)]),
    acres     = round(acres),
    poly_id   = row_number(),
    bps_doc_url = paste0("https://github.com/rswaty/bps_docs_parse/raw/main/all_bps_docs/",
                         bps_model, ".docx")
  ) |>
  select(poly_id, group, bps_name, bps_model, acres, pct_group, color, bps_doc_url)


# Summaries and outputs ----

raw_acres <- bps_atts |>
  inner_join(conifer_bps, by = "BPS_CODE") |>
  group_by(group) |>
  summarize(raw_acres = sum(ACRES))

conifer_summary <- conifer_polys |>
  st_drop_geometry() |>
  group_by(group) |>
  summarize(n_polys = n(), smoothed_acres = sum(acres)) |>
  left_join(raw_acres, by = "group") |>
  mutate(pct_retained = round(100 * smoothed_acres / raw_acres))

print(conifer_summary)
cat(sprintf("Total vertices: %s\n",
            format(nrow(st_coordinates(conifer_polys)), big.mark = ",")))

unlink("outputs/conifer_bps_smooth.gpkg")
st_write(conifer_polys, "outputs/conifer_bps_smooth.gpkg", quiet = TRUE)

write_csv(conifer_summary, "outputs/conifer_bps_smooth_summary.csv")


# Review figure ----

## zoom window: mid-sized pine patch whose window sits inside the forest
half_w <- 4000

zoom_candidates <- conifer_polys |>
  filter(group == "Pine (red/white)") |>
  arrange(abs(acres - 1500)) |>
  st_geometry() |>
  st_point_on_surface() |>
  st_coordinates()

for (i in seq_len(nrow(zoom_candidates))) {
  zx <- unname(zoom_candidates[i, "X"] + c(-half_w, half_w))
  zy <- unname(zoom_candidates[i, "Y"] + c(-half_w, half_w))
  zoom_box <- st_as_sfc(st_bbox(c(xmin = zx[1], ymin = zy[1], xmax = zx[2], ymax = zy[2]),
                                crs = st_crs(5070)))
  inside <- as.numeric(st_area(st_intersection(zoom_box, st_geometry(shp)))) / (4 * half_w^2)
  if (length(inside) && inside >= 0.95) break
}

raw_zoom <- crop(bps, ext(zx[1], zx[2], zy[1], zy[2])) |>
  as.data.frame(xy = TRUE) |>
  setNames(c("x", "y", "VALUE")) |>
  left_join(bps_lut, by = "VALUE") |>
  left_join(conifer_bps, by = "BPS_CODE") |>
  mutate(group = factor(group, levels = group_levels))

polys_zoom <- st_crop(conifer_polys, zoom_box)

p_full <- ggplot() +
  geom_sf(data = shp, fill = "grey95", color = "grey40", linewidth = 0.3) +
  geom_sf(data = conifer_polys, aes(fill = group), color = NA) +
  geom_sf(data = zoom_box, fill = NA, color = "black", linewidth = 0.8) +
  scale_fill_manual(values = group_colors, name = NULL, drop = FALSE) +
  labs(title = "Conifer-associated BpSs, smoothed polygons",
       subtitle = sprintf(paste0("90 m share, Gaussian sigma = %d m, contour at %.0f%%, min %d ac; ",
                                 "overlaps go to rarer types.\nBlack box = zoom panels."),
                          sigma_m, share_cut * 100, min_acres)) +
  theme_void(base_size = 14) +
  theme(legend.position = "bottom")

p_raw <- ggplot() +
  geom_raster(data = raw_zoom, aes(x, y, fill = group)) +
  scale_fill_manual(values = group_colors, na.value = "grey92", guide = "none") +
  coord_sf(crs = 5070, expand = FALSE, xlim = zx, ylim = zy) +
  labs(title = "Raw 30 m BpS pixels (zoom)") +
  theme_void(base_size = 14)

p_smooth <- ggplot() +
  geom_raster(data = raw_zoom, aes(x, y, fill = group), alpha = 0.35) +
  geom_sf(data = polys_zoom, aes(color = group), fill = NA, linewidth = 0.9) +
  scale_fill_manual(values = group_colors, na.value = "grey92", guide = "none") +
  scale_color_manual(values = group_colors, guide = "none") +
  coord_sf(crs = 5070, expand = FALSE, xlim = zx, ylim = zy) +
  labs(title = "Smoothed outlines over raw pixels (zoom)") +
  theme_void(base_size = 14)

review <- arrangeGrob(p_full, p_raw, p_smooth,
                      layout_matrix = rbind(c(1, 1), c(1, 1), c(2, 3)),
                      heights = c(0.65, 0.65, 1))

ggsave("outputs/conifer_bps_smooth_review.jpg", review,
       width = 14, height = 16, dpi = 150, bg = "white")
