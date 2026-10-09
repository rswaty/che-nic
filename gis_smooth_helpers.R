
# Notes ----
## Shared helpers: turn a 0/1 raster mask into smoothed (rounded) polygons
## approach: share at agg_fact resolution -> Gaussian blur -> contour (isoband)
## sourced by gis_conifer_bps_03.R and gis_canopy_openings_04.R
## code by Randy Swaty

library(isoband)
library(sf)
library(terra)

m2_per_acre <- 4046.8564224

fill_small_holes <- function(geom, min_m2) {
  polys <- lapply(geom, function(p) {
    rings <- unclass(p)
    keep  <- c(TRUE, vapply(rings[-1], function(r) {
      abs(sum(r[-1, 1] * r[-nrow(r), 2] - r[-nrow(r), 1] * r[-1, 2])) / 2 >= min_m2
    }, logical(1)))
    st_polygon(rings[keep])
  })
  st_sfc(polys, crs = st_crs(geom))
}

as_polygons <- function(x) {
  if (inherits(x, "sf")) x <- st_set_agr(x, "constant")
  if (any(st_geometry_type(x) == "GEOMETRYCOLLECTION")) {
    x <- st_collection_extract(x, "POLYGON")
  }
  x |>
    st_cast("MULTIPOLYGON") |>
    st_cast("POLYGON")
}

## mask: SpatRaster with 1 = in class, 0 = not, NA = outside area of interest
## clip: sf polygon used to trim the smoothed result
smooth_mask <- function(mask, clip, agg_fact = 3, sigma_m = 100, share_cut = 0.4,
                        min_hole_ac = 40, simplify_m = 15) {
  share <- if (agg_fact > 1) {
    aggregate(mask, fact = agg_fact, fun = "mean", na.rm = TRUE)
  } else {
    mask
  }
  share <- subst(share, NA, 0)

  w      <- focalMat(share, sigma_m, type = "Gauss")
  smooth <- focal(share, w, fun = "sum", na.rm = TRUE)

  z <- as.matrix(smooth, wide = TRUE)
  z[is.na(z)] <- 0
  z <- z[nrow(z):1, ]
  x <- xFromCol(smooth, 1:ncol(smooth))
  y <- rev(yFromRow(smooth, 1:nrow(smooth)))

  bands <- isobands(x, y, z, levels_low = share_cut, levels_high = 1.01)
  geom  <- st_sfc(iso_to_sfg(bands), crs = st_crs(clip)) |>
    st_make_valid() |>
    as_polygons()

  geom <- fill_small_holes(geom, min_hole_ac * m2_per_acre)

  st_sf(geometry = geom) |>
    st_intersection(st_geometry(clip)) |>
    as_polygons() |>
    st_simplify(dTolerance = simplify_m, preserveTopology = TRUE)
}
