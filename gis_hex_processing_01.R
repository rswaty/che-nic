

# Notes ----
## LANDFIRE data GIS Processing
## downloads data; makes hex shapefile for leaflet map
## run this first
## code by Randy Swaty
## December 15, 2025

# Set up ----

## load packages

library(exactextractr)
library(janitor)
library(raster)
library(rlandfire)
library(sf)
library(terra)
library(tidyverse)


# load landscape name and shape

landscape_name <- "Chequamegon-Nicolet National Forest"

shp <- st_read("inputs/cnnf.shp") %>%
  st_transform(crs = 5070) %>%
  st_make_valid() %>%
  st_union() %>%
  st_sf()

# used by script 02 for clip/mask (same extent as AOI)
shp_buffered <- shp

plot(shp)

# load conus-wide LANDFIRE attribute tables for joining later

bps_url <- "https://landfire.gov/sites/default/files/CSV/LF2016/LF16_BPS.csv" # will likely get warning, but it's OK
bps_conus_atts <- read.csv(bps_url)

evt_url <- "https://landfire.gov/sites/default/files/CSV/2024/LF2024_EVT.csv" # will likely get warning, but it's OK
evt_conus_atts <- read.csv(evt_url)

scl_url <- "https://landfire.gov/sites/default/files/CSV/2024/LF2024_SClass.csv"
scl_conus_atts <- read.csv(scl_url)


# accessible versions from Sarah Hagen for maps and charts


evc_conus_atts <- read.csv("inputs/LF22_EVC_230_acc.csv")

evh_conus_atts <- read.csv("inputs/LF22_EVH_230_acc.csv")

# Download LANDFIRE data for Area of Interest (AoI), manage that data ----
# skip download if already present (saves a long API round-trip)

if (!file.exists("inputs/landfire_data.tif")) {
  aoi <- getAOI(shp)

  products <-  c("LF2020_BPS", "LF2024_SClass", "LF2024_EVC", "LF2024_EVH", "LF2024_EVT")  
  projection <- 5070  
  resolution <- 30
  email <- "rswaty@tnc.org" # REPLACE WITH YOUR E-MAIL ADDRESS PLEASE! 

  # R specific arguments
  save_file <- tempfile(fileext = ".zip")


  # call API
  ncal <- landfireAPIv2(
    products, 
    aoi, 
    projection, 
    resolution, 
    path = save_file,
    email = email)


  # define the destination path
  dest_file <- file.path("inputs", "landfire_data.zip")

  # move and rename the file
  file.rename(save_file, dest_file)

  # create a temporary directory for unzipping
  temp_dir <- tempfile()
  dir.create(temp_dir)

  # unzip the file into the temporary directory
  unzip(dest_file, exdir = temp_dir)

  # get the list of unzipped files
  unzipped_files <- list.files(temp_dir, full.names = TRUE)

  # rename each unzipped file to "landfire_data" with its full original extension
  for (file in unzipped_files) {
    file_name <- basename(file)
    file_extension <- sub("^[^.]*", "", file_name)  # Extract the full extension
    new_file_path <- file.path("inputs", paste0("landfire_data", file_extension))
    file.rename(file, new_file_path)
  }

  # clean up the temporary directory
  unlink(temp_dir, recursive = TRUE)
} else {
  message("Using existing inputs/landfire_data.tif")
}


# Process datasets ----

# load in downloaded LANDFIRE tif
stacked_rasters <- rast("inputs/landfire_data.tif")

# "split" downloaded raster into separate layers
for(lyr in names(stacked_rasters)) assign(lyr, stacked_rasters[[lyr]])


## Create hexgrids for BpS, EVT, EVC and EVH ----


# --- parameters ---
acres_target <- 10000
m2_per_acre  <- 4046.8564224

# 0) ensure projected CRS in meters (critical for area-based sizing)
# if shp is lon/lat, transform to a suitable equal-area / meter-based CRS first
if (sf::st_is_longlat(shp)) {
  # pick something reasonable; adjust if you have a preferred projection
  shp <- st_transform(shp, 5070)  # NAD83 / Conus Albers (meters)
}

# 1) compute hex side length from target area
A_m2     <- acres_target * m2_per_acre
hex_side <- sqrt((2 * A_m2) / (3 * sqrt(3)))  # side length s (meters)

# 2) make a grid that DEFINITELY covers shp:
# expand bbox by ~one cell to avoid edge miss due to rounding
bb  <- st_bbox(shp)
pad <- 2 * hex_side
bb_exp <- bb
bb_exp[c("xmin","ymin")] <- bb_exp[c("xmin","ymin")] - pad
bb_exp[c("xmax","ymax")] <- bb_exp[c("xmax","ymax")] + pad

# create an sfc bbox in same CRS
bb_sfc <- st_as_sfc(bb_exp, crs = st_crs(shp))

# 3) build full hex grid over expanded bbox
# NOTE: with square = FALSE, sf creates hexagons; cellsize is the grid spacing parameter
hex_grid <- st_make_grid(
  bb_sfc,
  cellsize = c(1.5 * hex_side, sqrt(3) * hex_side),
  square   = FALSE,
  what     = "polygons"
) |>
  st_sf(geometry = _, crs = st_crs(shp)) |>
  mutate(hex_id = row_number())

# 4) keep FULL hexes that touch shp (NO clipping)
# st_intersects keeps any hex with ANY overlap -> guarantees coverage of shp
hex_grid_full <- hex_grid[ lengths(st_intersects(hex_grid, shp)) > 0, ] |>
  mutate(
    index     = row_number(),
    acres_est = as.numeric(st_area(geometry)) / m2_per_acre
  )

# quick check: area should be ~ constant and near acres_target
cat(sprintf(
  "Mean full hex area: %.1f acres (target = %.1f)\n",
  mean(hex_grid_full$acres_est, na.rm = TRUE),
  acres_target
))

## results in 7,500 ac hex which is OK

# plot
plot(st_geometry(hex_grid_full), col = NA, border = "gray40")
plot(st_geometry(shp), add = TRUE, border = "red", lwd = 2)

## Extract values and add them to hexgrid ----

# bps
bps_majority_hex <- exact_extract(LF2020_BPS_CONUS, hex_grid_full, 'majority', append_cols = "index") %>%
  left_join(dplyr::select(bps_conus_atts,
                          VALUE,
                          BPS_MODEL,
                          BPS_NAME,
                          FRI_ALLFIR),
            by = c('majority' = 'VALUE')) %>%
  rename(bps_value = majority) |>
  clean_names()



# evt
evt_majority_hex <- exact_extract(LF2024_EVT_CONUS, hex_grid_full, 'majority', append_cols = "index") %>%
  left_join(dplyr::select(evt_conus_atts,
                          VALUE,
                          EVT_NAME,
                          EVT_PHYS),
            by = c('majority' = 'VALUE')) |>
  rename(evt_value = majority) |>
  clean_names()

# evc
evc_majority_hex <- exact_extract(LF2024_EVC_CONUS, hex_grid_full, 'majority', append_cols = "index") %>%
  left_join(dplyr::select(evc_conus_atts,
                          Value,
                          CLASSNAMES),
            by = c('majority' = 'Value')) |>
  rename(evc_value = majority,
         evc_labels = CLASSNAMES) |>
  clean_names()

# evh
evh_majority_hex <- exact_extract(LF2024_EVH_CONUS, hex_grid_full, 'majority', append_cols = "index") %>%
  left_join(dplyr::select(evh_conus_atts,
                          Value,
                          CLASSNAMES),
            by = c('majority' = 'Value')) |>
  rename(evh_value = majority,
         evh_labels = CLASSNAMES) |>
  clean_names()



# Join both BpS and EVT attributes to hex shapefile
hexs_bps_evt_evc_evh <- hex_grid_full %>%
  left_join(bps_majority_hex, by = 'index') %>%
  left_join(evt_majority_hex, by = 'index') %>%
  left_join(evc_majority_hex, by = 'index') %>%
  left_join(evh_majority_hex, by = 'index') |>
  clean_names()


# save the shapefile for mapping in non-R applications or to read back into R
# unlink first so leftover Git LFS pointer stubs do not block GDAL

unlink("outputs/landfire_hexes.gpkg")
st_write(hexs_bps_evt_evc_evh, "outputs/landfire_hexes.gpkg", delete_layer = TRUE)

# dissolved AOI blob for locator-style maps in Quarto
shp_blob <- shp |>
  st_transform(4326) |>
  st_make_valid()
unlink("outputs/shp_blob.gpkg")
st_write(shp_blob, "outputs/shp_blob.gpkg", delete_layer = TRUE)














