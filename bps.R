

## Clip and Make Attribute Tables ----

## BpS ----

bps_aoi <- US_200BPS %>%
  crop(shp) %>%
  mask(shp)

# plot(bps_aoi)

levels(bps_aoi)[[1]] <- bps_conus_atts
activeCat(bps_aoi) <- "VALUE"

bps_aoi_atts <- values(bps_aoi, dataframe = T, na.rm = T) %>%
  table(dnn = "VALUE") %>%
  as.data.frame() %>%
  mutate_all(as.character) %>%
  mutate_all(as.integer) %>%
  left_join(cats(bps_aoi)[[1]], by = "VALUE") %>%
  filter(Freq != 0) %>%
  mutate(ACRES = round((Freq * 900 / 4046.86), 0),
         REL_PERCENT = round((Freq / sum(Freq)), 3) * 100) %>%
  arrange(desc(REL_PERCENT))

# write
writeRaster(bps_aoi, "outputs/bps_aoi.tif",
            gdal = c("COMPRESS=NONE", "TFW=YES"),
            datatype = "INT2S",
            overwrite = T)

write.dbf(bps_aoi_atts, "outputs/bps_aoi.tif.vat.dbf")

write.csv(bps_aoi_atts, "outputs/bps_aoi_attributes.csv")




