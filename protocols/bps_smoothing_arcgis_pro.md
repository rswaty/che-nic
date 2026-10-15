# Smoothed Biophysical Settings polygons in ArcGIS Pro

A protocol for turning a 30 m LANDFIRE Biophysical Settings (BpS) raster into rounded, natural-looking polygons for one or more groups of BpSs, for any area of interest. The same steps work for any categorical raster (e.g., Existing Vegetation Type) by swapping the field used to define groups.

## Why not just Raster to Polygon?

Converting a classified raster directly to polygons ([Raster to Polygon](https://pro.arcgis.com/en/pro-app/latest/tool-reference/conversion/raster-to-polygon.htm)) traces pixel edges, so polygons come out stair-stepped, with thousands of tiny slivers. Smoothing the polygons afterwards ([Smooth Polygon](https://pro.arcgis.com/en/pro-app/latest/tool-reference/cartography/smooth-polygon.htm)) softens corners but keeps every speck. This protocol smooths the *raster* first, then contours it:

1. For each group, make a 1/0 raster (1 = pixel belongs to the group).
2. Average it to a coarser cell size, so each cell holds the group's share of that cell.
3. Blur that share with a moving-window average, so each cell holds the group's share of its *neighborhood*.
4. Draw the contour at a chosen share (e.g., 40%), and keep the area above it.

Contour lines are interpolated between cell centers, so the polygons are naturally rounded. The amount of blur controls how much detail is kept; the contour level controls how inclusive the polygons are.

This is a form of **cartographic generalization**: deliberately simplifying a map to suit its scale and purpose. In effect, step 3 is a moving-window *proportion* of the group (the same idea as a kernel density surface), and step 4 traces an *isoline* of that surface, much like drawing an elevation contour on a DEM. See [Learn more](#learn-more) for background on each piece.

## Settings

Starting values that worked well on a ~1.5 million acre national forest. Adjust them to your landscape and map scale (see [Tuning](#tuning)).

| Setting | Starting value | Effect |
|---|---|---|
| Aggregation | 3 × 3 cells (30 m → 90 m), mean | Speeds processing; each cell = share of group |
| Blur | 3 × 3 cell mean, one pass | More passes = rounder, less detail |
| Contour level | 0.4 (40% neighborhood share) | Lower = more inclusive, picks up narrow strips |
| Fill holes smaller than | 40 acres | Removes pinholes |
| Simplify tolerance | 15 m (Douglas-Peucker) | Thins vertices for web maps |
| Minimum polygon size | 20 acres | Drops small patches |

## Before you start: define groups

Decide which BpSs to map and how to group them. A group can be a single BpS or several related ones (e.g., all spruce-fir variants). For each group, record:

- **Group name**
- **BPS_CODE values** in the group. Use `BPS_CODE`, not the raster `VALUE`: one BpS code can have several raster values (map zone variants), and the group should include all of them. Step 2 explains how to find the codes. Read the [BpS model descriptions](https://landfire.gov/vegetation/bps-models) to decide which BpSs belong together.
- **Priority**, if mapping more than one group. Groups are smoothed independently, so their edges can overlap; overlaps go to the higher-priority group (step 9). Putting rarer or more important groups first keeps them from being swallowed by widespread neighbors.
- **Color.** The colorblind-safe [Okabe-Ito palette](https://jfly.uni-koeln.de/color/) works well: #0072B2, #F0E442, #56B4E9, #009E73, #CC79A7, #E69F00, #D55E00, #000000. Leave a few colors unused if other layers will be drawn on top.

A worksheet like this keeps things straight. Number the groups by priority; that number (`g1`, `g2`, ...) is used in every output name.

| Priority | Group | BPS_CODE values | Color |
|---|---|---|---|
| 1 | *Group A* | *code, code, ...* | *#0072B2* |
| 2 | *Group B* | *code* | *#009E73* |
| ... | | | |

## Requirements

- ArcGIS Pro with the [Spatial Analyst](https://pro.arcgis.com/en/pro-app/latest/help/analysis/spatial-analyst/basics/what-is-the-spatial-analyst-extension.htm) extension (Aggregate, Focal Statistics, Contour, Lookup, Tabulate Area).
- A BpS raster covering the area of interest, with its attribute table (`BPS_CODE` field). Download from [landfire.gov](https://landfire.gov) (e.g., via the [LANDFIRE viewer](https://www.landfire.gov/viewer/)).
- An area-of-interest boundary polygon.

## Set up the project

1. **Create a project.** Open ArcGIS Pro and start a new project from the **Map** template. Pro creates a project file geodatabase (`YourProject.gdb`). Save every output there unless told otherwise; geodatabases handle long field names and large polygons better than shapefiles.
2. **Add data.** On the **Map** tab, click **Add Data** and add the BpS raster and the boundary polygon.
3. **Check the BpS attribute table.** In the **Contents** pane, right-click the BpS raster and choose **Attribute Table**. You should see `VALUE`, `BPS_CODE`, `BPS_NAME` and other fields. If only `VALUE` and `COUNT` are present, the attributes were lost (this can happen after clipping). Use [Join Field](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/join-field.htm) to bring them back from the CSV attribute table that comes with the LANDFIRE download, joining on `VALUE`.
4. **Trim the raster if it is much larger than your area.** If the BpS raster covers a whole region or the country, use **Clip Raster** to cut it to your boundary's extent plus a buffer of about 1 km. The buffer lets polygons at the edge "see" real neighbors during the blur; the polygons are clipped to the exact boundary later (step 7).
5. **Set environments.** On the **Analysis** tab, click **Environments** and set:
   - [Output Coordinate System](https://pro.arcgis.com/en/pro-app/latest/tool-reference/environment-settings/output-coordinate-system.htm): a projected system in meters. Choosing **Same as Input** with the BpS raster's projection (NAD 1983 Contiguous USA Albers, EPSG 5070, for CONUS LANDFIRE) works. Avoid geographic (degrees) coordinates; areas and distances would be wrong.
   - **Processing Extent:** same as the BpS raster.
   - [Snap Raster](https://pro.arcgis.com/en/pro-app/latest/tool-reference/environment-settings/snap-raster.htm): the BpS raster. This keeps every raster output aligned to the same grid.
   - Leave **Mask** empty. Cells outside the boundary need to be 0, not NoData, for the blur (handled in step 3).

   See [Geoprocessing environment settings](https://pro.arcgis.com/en/pro-app/latest/help/analysis/geoprocessing/basics/geoprocessing-environment-settings.htm) for details.

### Running tools

- **Open a tool:** on the **Analysis** tab, click **Tools**. In the **Geoprocessing** pane, search for the tool by name, fill in the parameters and click **Run**.
- **Check results:** a green banner means success. Click **View Details** to see warnings; some are harmless, but read them.
- **Rerun with different inputs:** on the **Analysis** tab, click **History**. Double-click a previous run to reopen the tool with the same settings, then change the inputs and output names. This is the fastest way to repeat steps 2–8 for each group ([Geoprocessing history](https://pro.arcgis.com/en/pro-app/latest/help/analysis/geoprocessing/basics/geoprocessing-history.htm)).
- **Automating:** steps 2–8 can be chained in [ModelBuilder](https://pro.arcgis.com/en/pro-app/latest/help/analysis/geoprocessing/modelbuilder/what-is-modelbuilder-.htm), with the group codes and name as model parameters. Steps 9 and 11 include Python you can paste into the [Python window](https://pro.arcgis.com/en/pro-app/latest/arcpy/get-started/python-window.htm) (**Analysis** tab > **Python** > **Python Window**).

## Step-by-step

Steps 2–8 are run once per group. Names below use `gX` for the group's priority number (`g1`, `g2`, ...), so `gX_mask` means `g1_mask` for the first group, `g2_mask` for the second, and so on.

### 1. Make a BPS_CODE raster

The BpS raster's cell values are `VALUE` codes; we want cells to hold `BPS_CODE` instead, so a group can be selected by code.

[Lookup](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/lookup.htm) (Spatial Analyst)

- Input raster: BpS raster
- Lookup field: `BPS_CODE`
- Output raster: `bps_code`

**Check:** click a few cells with the **Explore** tool. The pop-up value should be a 5-digit code (e.g., 13022) that matches `BPS_CODE` for that pixel in the BpS raster.

### 2. Make a 1/0 raster for the group

**Find the group's codes.**

1. Open the BpS raster's attribute table.
2. Click **Select By Attributes** and build a query on `BPS_NAME`, e.g., `BPS_NAME` *contains the text* `Spruce`.
3. Note the distinct `BPS_CODE` values among the selected rows. Several rows may share one code; list each code once.
4. Record the codes in your worksheet.

**Make the mask** with [Raster Calculator](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/raster-calculator.htm) (Spatial Analyst), using [Con](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/con-.htm) and [InList](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/inlist.htm). Double-click `bps_code` in the **Rasters** list to insert it, then type the rest:

```
Con(InList("bps_code", [13651, 13652, 13653]), 1, 0)
```

Replace the codes with your group's codes.

- Output raster: `gX_mask`

Cells outside the BpS raster's data area stay NoData; that is expected.

If `InList` is unavailable in your version, use `Con(("bps_code" == 13651) | ("bps_code" == 13652), 1, 0)`, or [Reclassify](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/reclassify.htm) the group's codes to 1 and all other codes to 0.

**Check:** symbolize `gX_mask` with **Unique Values** (1 in a bright color, 0 with no color). The 1s should match the group's pixels in the BpS raster.

### 3. Aggregate and fill NoData with 0

Aggregating converts 1/0 pixels into a share. For example, a 90 m cell containing 4 group pixels out of 9 gets a value of 0.44.

[Aggregate](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/aggregate.htm) (Spatial Analyst; see [How Aggregate works](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/how-aggregate-works.htm))

- Input raster: `gX_mask`
- Output raster: `gX_share`
- Cell factor: `3`
- Aggregation technique: `Mean`
- Expand extent if needed: checked
- Ignore NoData in calculations: **checked** (cells at the edge average only their valid pixels)

Then **Raster Calculator**:

```
Con(IsNull("gX_share"), 0, "gX_share")
```

- Output raster: `gX_sharez`

**Check:** the output is floating point, ranging from 0 to 1, with a 90 m cell size (**Properties** > **Source** > **Raster Information**).

### 4. Blur

Each cell gets the average of itself and its 8 neighbors, so it now holds the group's share of a 270 m × 270 m neighborhood.

[Focal Statistics](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/focal-statistics.htm) (Spatial Analyst; see [How Focal Statistics works](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/how-focal-statistics-works.htm))

- Input raster: `gX_sharez`
- Output raster: `gX_smooth`
- Neighborhood: `Rectangle`
- Height: `3`, Width: `3`, Units type: `Cell`
- Statistics type: **Mean**
- Ignore NoData in calculations: checked

**Check:** values still range from 0 to 1, and the surface looks like a soft-focus version of `gX_sharez`.

**Optional: extra passes.** For rounder, simpler polygons, run Focal Statistics again with the same settings on `gX_smooth`, then contour that output instead. Each pass blurs a little more. Repeated averaging approaches a Gaussian blur; with 90 m cells, one pass blurs by about 73 m, two passes by about 104 m and three by about 127 m. One pass works well for most uses. When tested on a 1.5 million acre forest, two passes cut the polygon count by about 20% and changed total acres by less than 1%.

### 5. Contour and keep the area above the level

[Contour](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/contour.htm) (Spatial Analyst; see [How Contouring works](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/how-contouring-works.htm))

- Input raster: `gX_smooth`
- Output feature class: `gX_bands`
- Contour interval: your contour level (e.g., `0.4`)
- Base contour: `0`
- Contour type: **Contour polygon**

The output is a set of non-overlapping bands: 0–0.4, 0.4–0.8 and 0.8 up to the maximum. Setting the interval equal to the level guarantees a band boundary exactly at the level.

**Keep the bands at or above the level:**

1. Open the attribute table of `gX_bands`. It has fields holding each band's lower and upper contour values; field names vary by Pro version.
2. [Select Layer By Attribute](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/select-layer-by-attribute.htm): new selection, where the lower-value field is greater than or equal to `0.399`. The 0.399 allows for values stored as 0.39999999.
3. [Pairwise Dissolve](https://pro.arcgis.com/en/pro-app/latest/tool-reference/analysis/pairwise-dissolve.htm) with the selection active (only selected features are used):
   - Input features: `gX_bands`
   - Output feature class: `gX_contour`
   - Dissolve fields: none
   - Create multipart features: checked

   This merges the selected bands into one feature: everywhere the neighborhood share is at least the level.

Alternative: **Contour shell up** returns overlapping "shells", each running from a contour value up to the raster maximum. Keep the shell whose lower value equals your level, and delete the rest.

**Check:** symbolize `gX_smooth` with two classes, breaking at the contour level, and overlay `gX_contour` as a hollow outline. The outline should trace the class break, with the high class inside.

### 6. Fill small holes

[Eliminate Polygon Part](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/eliminate-polygon-part.htm) (Data Management)

- Input features: `gX_contour`
- Output feature class: `gX_filled`
- Condition: `Area`
- Area: e.g., `40 Acres`
- Eliminate contained parts only: **checked** (removes holes only; outer polygons of any size are kept)

### 7. Clip to the area of interest

[Pairwise Clip](https://pro.arcgis.com/en/pro-app/latest/tool-reference/analysis/pairwise-clip.htm) (Analysis)

- Input features: `gX_filled`
- Clip features: area-of-interest boundary
- Output feature class: `gX_clip`

Then [Multipart To Singlepart](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/multipart-to-singlepart.htm) (Data Management), so each separate patch becomes its own feature:

- Input features: `gX_clip`
- Output feature class: `gX_single`

### 8. Simplify and label

[Simplify Polygon](https://pro.arcgis.com/en/pro-app/latest/tool-reference/cartography/simplify-polygon.htm) (Cartography; see [How Simplify Line and Simplify Polygon work](https://pro.arcgis.com/en/pro-app/latest/tool-reference/cartography/how-simplify-line-works.htm))

- Input features: `gX_single`
- Output feature class: `gX_simple`
- Simplification algorithm: **Retain critical points (Douglas-Peucker)**
- Simplification tolerance: e.g., `15 Meters`
- Minimum area: `0`
- Handling topological errors: **Resolve topological errors** (keeps edges from crossing)
- Keep collapsed points: unchecked

Contours have a vertex every few meters; simplifying removes most of them without visibly changing the shape.

**Label the group.** Use [Add Field](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/add-field.htm) and [Calculate Field](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/calculate-field.htm) on `gX_simple` to add:

| Field | Type | Calculate Field expression (Python) |
|---|---|---|
| `group` | Text (length 100) | `"Group A"` (your group name, in quotes) |
| `priority` | Short | `1` (your group's priority number) |

**Repeat steps 2–8 for each group.** With only one group, skip step 9 and use `g1_simple` as the input to step 10.

### 9. Resolve overlaps by priority

**The problem.** Each group was smoothed on its own, so in mixed areas two groups can both pass the 40% contour and their polygons overlap. Picture a strip where pine and hemlock pixels are interspersed: after smoothing, the pine polygon and the hemlock polygon both cover the strip. If both were mapped, that strip would be counted twice in acreage totals, and the map would show two colors stacked on each other.

**The rule.** Each overlap goes to the higher-priority group. For each group, erase every area already covered by *any* higher-priority group. Group 1 keeps everything; group 2 loses what overlaps group 1; group 3 loses what overlaps groups 1 or 2; and so on.

**Worked example** for four groups:

| Group | Build the erase layer with Merge | Pairwise Erase input | Erase features | Output |
|---|---|---|---|---|
| g1 | (none: use [Copy Features](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/copy-features.htm) to copy `g1_simple`) | | | `g1_final` |
| g2 | (none: one layer) | `g2_simple` | `g1_simple` | `g2_final` |
| g3 | `g1_simple` + `g2_simple` → `above_g3` | `g3_simple` | `above_g3` | `g3_final` |
| g4 | `g1_simple` + `g2_simple` + `g3_simple` → `above_g4` | `g4_simple` | `above_g4` | `g4_final` |

Erasing with the `_simple` layers (before erase) gives the same result as erasing with the `_final` layers: together, groups 1 and 2 cover the same ground either way.

**Click by click (group 3 shown; repeat for each group from priority 2 down):**

1. Open [Merge](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/merge.htm) (Data Management).
   - Input datasets: add `g1_simple` and `g2_simple` (every group with a *higher* priority than the one you're processing)
   - Output dataset: `above_g3`
   - Leave the field map as is; the fields don't matter for erasing.

   The merged layer may contain overlapping polygons; that's fine.
2. Open [Pairwise Erase](https://pro.arcgis.com/en/pro-app/latest/tool-reference/analysis/pairwise-erase.htm) (Analysis).
   - Input features: `g3_simple`
   - Erase features: `above_g3`
   - Output feature class: `g3_final`

   Every part of `g3_simple` that falls inside `above_g3` is removed; everything else is copied with its attributes.

For group 2, skip the Merge and erase with `g1_simple` directly. For group 1, run Copy Features from `g1_simple` to `g1_final`.

Because the erasing edges are themselves smooth contours, the cut edges stay rounded.

**Or run it in the Python window.** This does the whole step for any number of groups. Edit the two lines marked `EDIT`:

```python
import arcpy

arcpy.env.workspace = r"C:\path\to\YourProject.gdb"  # EDIT: geodatabase with the gX_simple layers
arcpy.env.overwriteOutput = True

# EDIT: one entry per group, highest priority first
simple = ["g1_simple", "g2_simple", "g3_simple", "g4_simple"]

for k, fc in enumerate(simple, start=1):
    out = f"g{k}_final"
    if k == 1:
        arcpy.management.CopyFeatures(fc, out)
    elif k == 2:
        arcpy.analysis.PairwiseErase(fc, simple[0], out)
    else:
        above = f"above_g{k}"
        arcpy.management.Merge(simple[:k - 1], above)
        arcpy.analysis.PairwiseErase(fc, above, out)
    print(out, arcpy.management.GetCount(out)[0], "polygons")
```

**Check:**

- **Visual:** turn on `g1_simple` and `g2_simple` and find a place where they overlap. Then turn on `g1_final` and `g2_final` in the same place: `g2_final` should have a gap exactly where `g1_final` sits.
- **Area:** each `gX_final` should have the same or less area than its `gX_simple`. The difference is the overlap it gave up.
- **No overlaps remain:** run [Count Overlapping Features](https://pro.arcgis.com/en/pro-app/latest/tool-reference/analysis/count-overlapping-features.htm) (Analysis) with all `gX_final` layers as inputs and **Minimum Overlap Count** set to `2`. The output should be empty, or contain only slivers of a few square meters from coordinate rounding.

### 10. Combine and drop small polygons

1. [Merge](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/merge.htm) (Data Management)
   - Input datasets: all `gX_final` layers
   - Output dataset: `bps_smooth_all`
   - The `group` and `priority` fields match in every input, so the default field map keeps them.
2. [Multipart To Singlepart](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/multipart-to-singlepart.htm), because erasing can cut a polygon into pieces.
   - Input features: `bps_smooth_all`
   - Output feature class: `bps_smooth_parts`
3. Add a Double field `acres` to `bps_smooth_parts` with **Add Field**. Then run [Calculate Geometry Attributes](https://pro.arcgis.com/en/pro-app/latest/tool-reference/data-management/calculate-geometry-attributes.htm):
   - Input features: `bps_smooth_parts`
   - Field: `acres`; Property: **Area**
   - Area unit: **Acres**
4. Keep polygons at or above the minimum size with [Export Features](https://pro.arcgis.com/en/pro-app/latest/tool-reference/conversion/export-features.htm). This leaves `bps_smooth_parts` untouched, so you can try another minimum later.
   - Input features: `bps_smooth_parts`
   - Output feature class: `bps_smooth`
   - Filter: click **New Expression** and build `acres` *is greater than or equal to* `20`
5. Add a Long field `poly_id` to `bps_smooth` and use **Calculate Field** with the expression `!OBJECTID!`. This gives every polygon a stable ID for joins.

`bps_smooth` is the final product.

### 11. Optional: main BpS and purity per polygon

Smoothed polygons absorb some neighboring BpSs at their edges. Two attributes describe how "pure" each polygon is:

- **purity:** the share of the polygon's area made up of its own group's BpSs (0 to 1).
- **main_bps:** the group's BPS_CODE with the most area in the polygon. This is useful for groups with several BpSs.

Both come from [Tabulate Area](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/tabulate-area.htm) (Spatial Analyst), which measures how much of each BPS_CODE falls in each polygon:

- Input raster or feature zone data: `bps_smooth`
- Zone field: `poly_id`
- Input raster or feature class data: `bps_code` (from step 1)
- Class field: `Value`
- Output table: `tab_bps`
- Processing cell size: `30`

The output table has one row per polygon and one field per BPS_CODE, named `VALUE_<code>` (e.g., `VALUE_13022`), holding area in square meters.

Turning that table into purity and main BpS by hand is tedious, so paste this into the Python window. Edit the three `EDIT` lines; the group names must match the `group` field exactly.

```python
import arcpy
arcpy.CheckOutExtension("Spatial")

arcpy.env.workspace = r"C:\path\to\YourProject.gdb"  # EDIT
polys = "bps_smooth"
groups = {                                            # EDIT: group name -> its BPS_CODEs
    "Group A": [13651, 13652, 13653],
    "Group B": [13622],
}
cell_size = 30                                        # EDIT if your BpS raster is not 30 m

arcpy.sa.TabulateArea(polys, "poly_id", "bps_code", "Value", "tab_bps", cell_size)

tab_fields = [f.name for f in arcpy.ListFields("tab_bps")]
zone_field = next(f for f in tab_fields if f.lower() == "poly_id")
code_fields = [f for f in tab_fields if f.upper().startswith("VALUE_")]

areas = {}
with arcpy.da.SearchCursor("tab_bps", [zone_field] + code_fields) as cur:
    for row in cur:
        areas[row[0]] = {int(f.split("_")[1]): (v or 0) for f, v in zip(code_fields, row[1:])}

existing = [f.name for f in arcpy.ListFields(polys)]
for name, ftype in [("main_bps", "LONG"), ("purity", "DOUBLE")]:
    if name not in existing:
        arcpy.management.AddField(polys, name, ftype)

with arcpy.da.UpdateCursor(polys, ["poly_id", "group", "main_bps", "purity"]) as cur:
    for pid, grp, _, _ in cur:
        a = areas.get(pid, {})
        own = {code: a.get(code, 0) for code in groups[grp]}
        total = sum(a.values())
        main = max(own, key=own.get)
        purity = sum(own.values()) / total if total else None
        cur.updateRow([pid, grp, main, purity])

print("done")
```

To add the BpS name for `main_bps`, run **Join Field**:

- Input table: `bps_smooth`, Input field: `main_bps`
- Join table: the BpS raster, Join table field: `BPS_CODE`
- Transfer fields: `BPS_NAME`

**What to expect:** median purity of 70–80% with the starting settings. Small or narrow polygons tend to be less pure, because more of their area is edge.

### 12. Symbolize

1. In the **Contents** pane, right-click `bps_smooth` and choose **Symbology**.
2. Primary symbology: **Unique Values**. Field 1: `group`.
3. For each group, click its symbol, open **Properties**, and set the fill color. In the color dropdown choose **Color Properties** and type the hex code (e.g., `#0072B2`).
4. Set outlines to the same color as the fill or to a thin (0.5 pt) dark gray, so adjacent groups stay distinct.
5. Uncheck **Show all other values**.
6. Drag the classes into priority order so the legend matches your worksheet.
7. Select the layer, then on the **Feature Layer** tab, set **Layer Transparency** to about 40% so the basemap shows through.
8. To share the styling, right-click the layer, choose **Sharing** > **Save As Layer File**, and send the `.lyrx` file along with the data.

## Quality checks

- **Visual check:** zoom into a few areas with the raw BpS raster (group pixels highlighted) under the polygon outlines. Edges should follow the bulk of the pixels without stair steps.
- **Acreage check:** compare each group's smoothed acres to its raw pixel acres.
  - **Smoothed acres:** select the group in `bps_smooth` and look at the statistics of `acres`. Alternatively, run **Summary Statistics** with `acres` SUM and case field `group`.
  - **Raw acres:** the number of group pixels × 0.2224 acres for 30 m cells. Get the pixel count from the `COUNT` field of the BpS attribute table (summed over the group's rows) or from **Tabulate Area**.

  How to read the ratio of smoothed to raw acres:
  - **Roughly 90–110%:** typical for widespread groups that occur in large patches.
  - **Well above 100%:** the contour is absorbing neighboring types in mixed areas. Raise the contour level.
  - **Well below 100%:** the group occurs as small or scattered patches that fall below the contour level or the minimum size. Lower the contour level or the minimum size, if those patches matter.
- **Overlaps:** see the check at the end of step 9.

## Tuning

- **Rounder, simpler shapes:** add a second or third blur pass (step 4).
- **Capture narrow or scattered patches:** lower the contour level (e.g., 0.35). Expect polygons to grow into neighboring types.
- **Group-specific settings:** each group can use its own contour level or number of passes. Scattered types benefit from a lower contour level and a single pass.
- **Map scale:**
  - **Small areas or large-scale maps:** use a smaller minimum size, and possibly no aggregation (cell factor 1, so the blur works on 30 m cells; slower).
  - **Regional extents:** use a larger aggregation factor or more blur passes.
- **Simplify tolerance:** keep it well below the cell size so shapes stay rounded. Increase it only if file size matters (e.g., web maps).

When tuning, rerun only from the step whose setting changed:

| Setting | Rerun from |
|---|---|
| Blur passes | Step 4 |
| Contour level | Step 5 |
| Hole size | Step 6 |
| Simplify tolerance | Step 8 |
| Minimum polygon size | Step 10, item 4 |

## Caveats

- **Not current vegetation:** BpS represents vegetation that may have been dominant prior to Euro-American settlement. Smoothed BpS polygons do not map current vegetation.
- **Edges are approximate:** polygon edges are the chosen neighborhood-share line, not an observed boundary. Use the polygons for planning-scale display and screening, not site-level decisions.
- **Software differences:** results from ArcGIS Pro and other software (e.g., the R `terra` + `isoband` equivalent) differ slightly because contour interpolation and simplification algorithms differ. Expect differences of a few percent in acres.

## Learn more

### LANDFIRE and Biophysical Settings

- [LANDFIRE home](https://landfire.gov): data downloads, documentation and training.
- [Biophysical Settings overview](https://landfire.gov/vegetation/bps): what BpS represents and how it was mapped.
- [BpS models and descriptions](https://landfire.gov/vegetation/bps-models): the description document for each BpS (vegetation, disturbance regimes, succession classes).
- [LANDFIRE viewer](https://www.landfire.gov/viewer/): browse and download data for an area of interest.
- Blankenship, K., R. Swaty, K.R. Hall, S. Hagen, et al. 2021. Vegetation dynamics models: a comprehensive set for natural resource assessment and planning in the United States. *Ecosphere* 12(4):e03484. [doi:10.1002/ecs2.3484](https://doi.org/10.1002/ecs2.3484)
- [rlandfire](https://CRAN.R-project.org/package=rlandfire): an R package for downloading LANDFIRE data by script.

### Concepts behind each step

| Concept | Where it is used | Resources |
|---|---|---|
| Map algebra and neighborhood (focal) operations | Steps 2–4 | [Map algebra (Wikipedia)](https://en.wikipedia.org/wiki/Map_algebra); [Overview of the Neighborhood tools](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/an-overview-of-the-neighborhood-tools.htm) |
| Changing resolution (aggregation) | Step 3 | [How Aggregate works](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/how-aggregate-works.htm) |
| Smoothing with a moving-window mean (and why repeated passes approach a Gaussian blur) | Step 4 | [How Focal Statistics works](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/how-focal-statistics-works.htm); [Gaussian blur (Wikipedia)](https://en.wikipedia.org/wiki/Gaussian_blur) |
| Contouring (isolines and isobands) | Step 5 | [How Contouring works](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/how-contouring-works.htm); [Marching squares (Wikipedia)](https://en.wikipedia.org/wiki/Marching_squares), the standard algorithm for tracing contours on a grid |
| Line simplification | Step 8 | [How Simplify Line and Simplify Polygon work](https://pro.arcgis.com/en/pro-app/latest/tool-reference/cartography/how-simplify-line-works.htm); [Ramer-Douglas-Peucker algorithm (Wikipedia)](https://en.wikipedia.org/wiki/Ramer%E2%80%93Douglas%E2%80%93Peucker_algorithm) |
| Overlay (erase, overlap) | Step 9 | [Pairwise Erase](https://pro.arcgis.com/en/pro-app/latest/tool-reference/analysis/pairwise-erase.htm); [Count Overlapping Features](https://pro.arcgis.com/en/pro-app/latest/tool-reference/analysis/count-overlapping-features.htm) |
| Zonal summaries | Step 11 | [Tabulate Area](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/tabulate-area.htm); [Zonal Statistics as Table](https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/zonal-statistics-as-table.htm) |
| Cartographic generalization | The whole workflow | [Cartographic generalization (Wikipedia)](https://en.wikipedia.org/wiki/Cartographic_generalization) |
| Minimum mapping unit | Steps 6 and 10 | Saura 2002 (below) |
| Accessible color | Step 12 | [Okabe and Ito, Color Universal Design](https://jfly.uni-koeln.de/color/); Wong 2011 (below) |

### Key papers

- Douglas, D.H., and T.K. Peucker. 1973. Algorithms for the reduction of the number of points required to represent a digitized line or its caricature. *Cartographica* 10(2):112–122. [doi:10.3138/FM57-6770-U75U-7727](https://doi.org/10.3138/FM57-6770-U75U-7727)
- Saura, S. 2002. Effects of minimum mapping unit on land cover data spatial configuration and composition. *International Journal of Remote Sensing* 23(22):4853–4880. [doi:10.1080/01431160110114493](https://doi.org/10.1080/01431160110114493)
- Wong, B. 2011. Points of view: Color blindness. *Nature Methods* 8:441. [doi:10.1038/nmeth.1618](https://doi.org/10.1038/nmeth.1618)

### Learning GIS

- [Learn ArcGIS](https://learn.arcgis.com/en/): free, guided ArcGIS Pro lessons. Search for "Spatial Analyst" or "raster analysis".
- [Data Carpentry: Introduction to Geospatial Raster and Vector Data with R](https://datacarpentry.org/r-raster-vector-geospatial/): beginner-friendly lessons.
- [Geocomputation with R](https://r.geocompx.org/): free online book; see the chapters on raster operations and geometry operations.
- [Spatial Data Science with R](https://rspatial.org/): tutorials for the `terra` package.
- [Spatial Data Science: With Applications in R](https://r-spatial.org/book/) (Pebesma and Bivand): free online book on `sf` and spatial data concepts.

### The same workflow in R

| ArcGIS Pro step | R function |
|---|---|
| Aggregate | [`terra::aggregate()`](https://rspatial.github.io/terra/reference/aggregate.html) |
| Focal Statistics (3 × 3 mean) | [`terra::focal(x, w = 3, fun = "mean")`](https://rspatial.github.io/terra/reference/focal.html) |
| Contour | [`isoband::isobands()`](https://isoband.r-lib.org/) |
| Simplify Polygon | [`sf::st_simplify()`](https://r-spatial.github.io/sf/reference/geos_unary.html) |
| Pairwise Erase | [`sf::st_difference()`](https://r-spatial.github.io/sf/reference/geos_binary_ops.html) |
