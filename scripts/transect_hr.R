library(paceR)
library(sp)
library(sf)
library(ggthemes)

load_pace_packages()

system("ssh -f camposf@pacelab.ucalgary.ca -L 3307:localhost:3306 -N")

pace_db <- src_mysql(group = "PACE", user = "camposf", dbname = "monkey", password = NULL)
paceR_db <- src_mysql(group = "PACE", user = "camposf", dbname = "paceR", password = NULL)

my_dir <- "data/"

# ---- vertical_transects -------------------------------------------------

tr_full <- get_pace_tbl(pace_db, "tblVegetationTransect")
tr_pt <- get_pace_tbl(pace_db, "tblVegetationTransectGridPoint")


vt <- rgdal::readOGR(dsn = paste0(my_dir, "v_transect_2016.gpx"), layer = "waypoints")

vt2 <- spTransform(vt, CRSobj = CRS("+init=epsg:32616"))

vt_df <- tbl_df(vt2) %>%
  select(name, x = coords.x1, y = coords.x2)

vt_df <- vt_df %>%
  mutate(endpoint = str_extract(name, "[a-zA-z]+"))

vt_df$name <- str_replace(vt_df$name, "End.", "")
vt_df$name <- str_replace(vt_df$name, "Start.", "")

vt_df <- vt_df %>%
  group_by(name) %>%
  mutate(endpoint = case_when(y == min(y) ~ "S.",
                              y == max(y) ~ "N."))

vt_df <- unite(vt_df, endpoint, endpoint, name, sep = "")

v_res <- select(tr_full, ID, TransectBegin, TransectEnd) %>%
  inner_join(vt_df, by = c("TransectBegin" = "endpoint")) %>%
  rename(start_x = x, start_y = y)

v_res <- v_res %>%
  inner_join(vt_df, by = c("TransectEnd" = "endpoint")) %>%
  rename(end_x = x, end_y = y)

v_res <- v_res %>%
  mutate(transect = str_extract(TransectBegin, "[0-9]+"))

tr_v <- select(v_res, -TransectBegin, -TransectEnd)

tr_v$transect <- paste0("v_", tr_v$transect)

# Set width
tr_v$radius <- 2



# ---- horizontal_transects -----------------------------------------------

tr_begin <- tr_full %>%
  select(ID, matches("Grid")) %>%
  inner_join(select(tr_pt, ID, GpsUtm), by = c("GridPointBeginID" = "ID")) %>%
  separate(GpsUtm, into = c("zone", "char", "x", "y"), sep = " ") %>%
  rename(start_x = x, start_y = y) %>%
  select(-matches("Grid"), -zone, -char)

tr_end <- tr_full %>%
  select(ID, matches("Grid")) %>%
  inner_join(select(tr_pt, ID, GpsUtm), by = c("GridPointEndID" = "ID")) %>%
  separate(GpsUtm, into = c("zone", "char", "x", "y"), sep = " ") %>%
  rename(end_x = x, end_y = y) %>%
  select(-matches("Grid"), -zone, -char)


tr_h <- inner_join(tr_begin, tr_end)

tr_h$transect <- paste0("h_", tr_h$ID)

tr_h <- mutate_at(tr_h, vars(-transect, -ID), as.numeric)

# Set width
tr_h$radius <- 1

all_tran <- bind_rows(tr_h, tr_v)

ggplot(all_tran, aes(x = start_x, xend = end_x, y = start_y, yend = end_y)) +
  geom_segment() +
  coord_equal() +
  theme_void()

ggplot(all_tran) +
  geom_segment(aes(x = start_x, xend = end_x, y = start_y, yend = end_y)) +
  geom_point(aes(x = start_x, y = start_y), size = 0.75) +
  geom_point(aes(x = end_x, y = end_y), size = 0.75) +
  coord_equal(xlim = c(min(all_tran$start_x), 652800)) +
  labs(x = NULL, y = NULL) +
  theme_minimal()

write_csv(all_tran, paste0(my_dir, "all_transects.csv"))


# ---- tr_buffers ---------------------------------------------------------

all_tran <- read_csv(paste0(my_dir, "all_transects.csv"))

get_line <- function(df) {
  res <- st_linestring(cbind(c(df$start_x, df$end_x), c(df$start_y, df$end_y)))
  return(res)
}

temp <- all_tran %>%
  group_by(ID, radius) %>%
  nest() %>%
  mutate(lines = purrr::map(data, ~ get_line(.)))

tran_lines <- temp$lines %>%
  st_sfc(crs = 32616)

tran_lines <- st_as_sf(data.frame(id = temp$ID,
                                  radius = temp$radius),
                       tran_lines)

tran_sl <- as(tran_lines, "Spatial")

tran_poly <- rgeos::gBuffer(tran_sl, byid = TRUE, capStyle = "flat",
                            width = tran_sl$radius)


# ---- overlap ------------------------------------------------------------

hr_dir <- paste0(my_dir, "hr_data/")
hr_files <- list.files(hr_dir, pattern = ".shp")

cap_groups <- str_extract(hr_files, "[A-Z]{2}")

hr_polys <- list(7)

# Read in hr polygons
for (i in seq_along(hr_files)) {
 hr_polys[[i]] <- rgdal::readOGR(dsn = paste0(hr_dir, hr_files[i]))
}

tr_overlap <- list(7)

for (i in seq_along(hr_polys)) {
  tr_overlap[[i]] <- over(hr_polys[[i]], tran_poly, returnList = TRUE)[[1]]$id
}

# Example plots; change value of i for different groups
i <- 6
test_hr <- hr_polys[[i]]
plot(test_hr)
plot(tran_poly[tran_poly$id %in% tr_overlap[[i]], ], add = TRUE)

# Create data frame
hr_df <- data_frame(id = cap_groups)
hr_df$tr_ids <- tr_overlap
hr_df$polys <- hr_polys



# ---- plots --------------------------------------------------------------

temp <- hr_df %>%
  select(id, polys) %>%
  mutate(poly_df = purrr::map(polys, ~fortify(.))) %>%
  select(-polys) %>%
  unnest()

temp1 <- hr_df %>%
  select(id, tr_ids) %>%
  unnest() %>%
  left_join(all_tran, by = c("tr_ids" = "ID"))

ggplot() +
  geom_polygon(data = filter(temp, id %in% c("RM", "GN", "LV")),
               aes(x = long, y = lat, group = group, fill = hole),
               color = "black") +
  geom_segment(data = all_tran,
               aes(x = start_x, xend = end_x, y = start_y, yend = end_y),
               size = 0.25, color = "gray70") +
  geom_segment(data = filter(temp1, id %in% c("RM", "GN", "LV")),
               aes(x = start_x, xend = end_x, y = start_y, yend = end_y),
               size = 0.25, color = "black") +
  facet_wrap(~ id, nrow = 1) +
  coord_equal() +
  theme_few() +
  theme(legend.position = "bottom",
        legend.key.width = unit(1, "cm"),
        axis.text.x = element_blank(),
        axis.text.y = element_blank(),
        axis.ticks = element_blank()) +
  scale_fill_manual(guide = FALSE, values = c("gray95", "white")) +
  labs(x = "", y = "")


# gplot(hab_stack) +
#   geom_raster(aes(fill = factor(value))) +
#   geom_polygon(data = filter(hr_polys, id %in% c("RM", "GN", "LV")),
#                aes(x = long, y = lat, group = group),
#                color = "black", fill = NA) +
#   facet_wrap(~ id, nrow = 1) +
#   geom_segment(data = tr,
#                aes(x = start_x, xend = end_x, y = start_y, yend = end_y),
#                size = 0.25, color = "black") +
#   scale_fill_manual(name = "Habitat", values = lc_grad,
#                     labels = c("Open", "Early", "Intermediate", "Late"),
#                     guide = FALSE) +
#   coord_equal() +
#   theme_few() +
#   theme(legend.position = "bottom", legend.key.width = unit(1, "cm"),
#         axis.text.x = element_blank(),
#         axis.text.y = element_blank(),
#         axis.ticks = element_blank()) +
#   labs(x = "", y = "")
#

ggplot() +
  geom_polygon(data = filter(temp, id %in% c("RM", "GN", "LV")),
               aes(x = long, y = lat, group = group, fill = hole),
               color = "black") +
  geom_segment(data = all_tran,
               aes(x = start_x, xend = end_x, y = start_y, yend = end_y),
               size = 0.25, color = "gray70") +
  geom_point(data = all_tran,
             aes(x = start_x, y = start_y),
             size = 0.25, color = "gray70") +
  geom_point(data = all_tran,
             aes(x = end_x, y = end_y),
             size = 0.25, color = "gray70") +
  geom_segment(data = filter(temp1, id %in% c("RM", "GN", "LV")),
               aes(x = start_x, xend = end_x, y = start_y, yend = end_y),
               size = 0.25, color = "black") +
  geom_point(data = filter(temp1, id %in% c("RM", "GN", "LV")),
               aes(x = start_x, y = start_y),
               size = 0.25, color = "black") +
  geom_point(data = filter(temp1, id %in% c("RM", "GN", "LV")),
             aes(x = end_x, y = end_y),
             size = 0.25, color = "black") +
  facet_wrap(~ id, nrow = 1) +
  # geom_segment(aes(x = start_x, xend = end_x, y = start_y, yend = end_y)) +
  # geom_point(aes(x = start_x, y = start_y), size = 0.75) +
  # geom_point(aes(x = end_x, y = end_y), size = 0.75) +
  coord_equal(xlim = c(min(all_tran$start_x) - 500, 652800)) +
  scale_fill_manual(guide = FALSE, values = c("gray95", "white")) +
  labs(x = NULL, y = NULL) +
  theme_minimal()
