# Smoothed Biophysical Settings polygons in ArcGIS Pro

A protocol for turning a 30 m LANDFIRE Biophysical Settings (BpS) raster into rounded, natural-looking polygons for one or more groups of BpSs, for any area of interest. The same steps work for any categorical raster (e.g., Existing Vegetation Type) by swapping the field used to define groups.

## Why not just Raster to Polygon?

Converting a classified raster directly to polygons traces pixel edges, so polygons come out stair-stepped, with thousands of tiny slivers. Smoothing the polygons afterwards (e.g., Smooth Polygon) softens corners but keeps every speck. This protocol smooths the *raster* first, then contours it:

1. For each group, make a 1/0 raster (1 = pixel belongs to the group).
2. Average it to a coarser cell size, so each cell holds the group's share of that cell.
3. Blur that share with a Gaussian kernel, so each cell holds the group's share of its *neighborhood*.
4. Draw the contour at a chosen share (e.g., 40%), and keep the area above it.

Contour lines are interpolated between cell centers, so the polygons are naturally rounded. The blur width (sigma) controls how much detail is kept; the contour level controls how inclusive the polygons are.

## Settings

Starting values that worked well on a ~1.5 million acre national forest. Adjust them to your landscape and map scale (see [Tuning](#tuning)).

| Setting | Starting value | Effect |
|---|---|---|
| Aggregation | 3 × 3 cells (30 m → 90 m), mean | Speeds processing; each cell = share of group |
| Gaussian sigma | 100 m (7 × 7 kernel at 90 m) | Larger = rounder, less detail |
| Contour level | 0.4 (40% neighborhood share) | Lower = more inclusive, picks up narrow strips |
| Fill holes smaller than | 40 acres | Removes pinholes |
| Simplify tolerance | 15 m (Douglas-Peucker) | Thins vertices for web maps |
| Minimum polygon size | 20 acres | Drops small patches |

## Before you start: define groups

Decide which BpSs to map and how to group them. A group can be a single BpS or several related ones (e.g., all spruce-fir variants). For each group, record:

- **Group name**
- **BPS_CODE values** in the group. Use `BPS_CODE`, not the raster `VALUE`: one BpS code can have several raster values (map zone variants), and the group should include all of them. Look the codes up in the raster attribute table or by filtering on `BPS_NAME` or `GROUPVEG`.
- **Priority**, if mapping more than one group. Groups are smoothed independently, so their edges can overlap; overlaps go to the higher-priority group. Putting rarer or more important groups first keeps them from being swallowed by widespread neighbors.
- **Color.** The colorblind-safe Okabe-Ito palette works well: #0072B2, #F0E442, #56B4E9, #009E73, #CC79A7, #E69F00, #D55E00, #000000. Leave a few colors unused if other layers will be drawn on top.

A worksheet like this keeps things straight:

| Priority | Group | BPS_CODE values | Color |
|---|---|---|---|
| 1 | *Group A* | *code, code, ...* | *#0072B2* |
| 2 | *Group B* | *code* | *#009E73* |
| ... | | | |

## Requirements

- ArcGIS Pro with the **Spatial Analyst** extension (Aggregate, Focal Statistics, Contour, Lookup).
- A BpS raster covering the area of interest, with its attribute table (`BPS_CODE` field). Download from [landfire.gov](https://landfire.gov) and clip to a bit beyond your boundary.
- An area-of-interest boundary polygon.
- A Gaussian kernel file. `gauss_kernel_90m_sigma100.txt` (in this folder) matches the starting settings. For other settings, generate one with the script in [Making a kernel file](#making-a-kernel-file).

## Environment settings

Set these once for the project (**Analysis > Environments**) before running any tools:

- **Output Coordinate System:** a projected system in meters. The LANDFIRE native projection (NAD 1983 Contiguous USA Albers, EPSG 5070, for CONUS) is a good choice. Avoid geographic (degrees) coordinates.
- **Processing Extent:** same as the BpS raster.
- **Snap Raster:** the BpS raster.
- Leave **Mask** empty. Cells outside the boundary need to be 0, not NoData, for the blur (handled in step 3).

## Step-by-step

Steps 2–8 are run once per group. Names below use `gX` for the group number.

### 1. Make a BPS_CODE raster

**Lookup** (Spatial Analyst)

- Input raster: BpS raster
- Lookup field: `BPS_CODE`
- Output: `bps_code`

### 2. Make a 1/0 raster for the group

**Raster Calculator** (Spatial Analyst):

```
Con(InList("bps_code", [code1, code2, code3]), 1, 0)
```

- Output: `gX_mask`

Cells outside the BpS raster's data area stay NoData; that is expected.

If `InList` is unavailable in your version, use `Con(("bps_code" == code1) | ("bps_code" == code2), 1, 0)`, or **Reclassify** the group's codes to 1 and all other codes to 0.

### 3. Aggregate and fill NoData with 0

**Aggregate** (Spatial Analyst)

- Input: `gX_mask`
- Cell factor: `3`
- Aggregation technique: `Mean`
- Expand extent if needed: checked
- Ignore NoData in calculations: **checked** (cells at the edge average only their valid pixels)
- Output: `gX_share`

Then **Raster Calculator**:

```
Con(IsNull("gX_share"), 0, "gX_share")
```

- Output: `gX_sharez`

The output is floating point, 0 to 1.

### 4. Gaussian blur

**Focal Statistics** (Spatial Analyst)

- Input: `gX_sharez`
- Neighborhood: `Weight`, Kernel file: your Gaussian kernel file
- Statistics type: **Sum**
- Ignore NoData: checked
- Output: `gX_smooth`

The kernel weights sum to 1, so **Sum** yields a weighted average (the neighborhood share). Do not use **Mean**: with a weight kernel it divides again by the cell count and shrinks all values.

The kernel must be built for the cell size of `gX_sharez` (90 m with the starting settings).

### 5. Contour and keep the area above the level

**Contour** (Spatial Analyst)

- Input: `gX_smooth`
- Contour interval: `1`
- Base contour: your contour level (e.g., `0.4`)
- Contour type: **Contour shell up** (polygons of the area at or above each contour value)
- Output: `gX_contour`

With interval 1, the only contour within the 0–1 range is the base level, so the output is the area where the neighborhood share is at least that level.

Check: overlay the output on `gX_smooth` symbolized with a break at the contour level. Polygons should cover the cells at or above it. If they cover the area *below* it instead, use **Contour polygon** with the contour level as the interval and base 0. Then keep only polygons whose minimum contour value is at or above the level, and **Dissolve** them.

### 6. Fill small holes

**Eliminate Polygon Part** (Data Management)

- Input: `gX_contour`
- Condition: `Area`
- Area: e.g., `40 Acres`
- Eliminate contained parts only: **checked** (removes holes only)
- Output: `gX_filled`

### 7. Clip to the area of interest

**Pairwise Clip** (Analysis)

- Input: `gX_filled`
- Clip features: area-of-interest boundary
- Output: `gX_clip`

Then **Multipart To Singlepart** (Data Management): output `gX_single`.

### 8. Simplify

**Simplify Polygon** (Cartography)

- Input: `gX_single`
- Algorithm: **Retain critical points (Douglas-Peucker)**
- Tolerance: e.g., `15 Meters`
- Minimum area: `0`
- Keep collapsed points: unchecked
- Output: `gX_simple`

Add a text field `group` and calculate it to the group name.

**Repeat steps 2–8 for each group.** With only one group, skip step 9.

### 9. Resolve overlaps by priority

Work down the priority list, erasing everything already claimed by higher-priority groups:

| Priority | Tool | Input | Erase features | Output |
|---|---|---|---|---|
| 1 | (none) | `g1_simple` | (none) | `g1_final` |
| 2 | Pairwise Erase | `g2_simple` | `g1_final` | `g2_final` |
| 3 | Pairwise Erase | `g3_simple` | merge of `g1_final`, `g2_final` | `g3_final` |
| n | Pairwise Erase | `gn_simple` | merge of all higher-priority finals | `gn_final` |

Use **Merge** (Data Management) to build each "claimed so far" layer, or erase sequentially one higher-priority layer at a time. The result is the same.

Because the erasing edges are themselves smooth contours, the cut edges stay rounded.

### 10. Combine and drop small polygons

1. **Merge** all `gX_final` layers into one output (e.g., `bps_smooth`).
2. **Multipart To Singlepart** (erasing can split polygons).
3. Add a double field `acres` and use **Calculate Geometry Attributes** (Area, Acres).
4. **Select Layer By Attribute** with `acres <` your minimum (e.g., 20), then **Delete Rows**. Alternatively, **Export Features** with the query `acres >= 20`.

### 11. Optional: main BpS and purity per polygon

1. Add a long integer field `poly_id` and calculate it from `OBJECTID`.
2. **Tabulate Area** (Spatial Analyst)
   - Input zone data: the merged polygons, zone field `poly_id`
   - Input class data: `bps_code` (from step 1), class field `Value`
   - Output: area of each BPS_CODE inside each polygon
3. For each polygon:
   - **Purity** is the area of the group's own BPS_CODEs divided by the polygon's total area.
   - **Main BpS** is the group code with the most area.

   Medians of 70–80% are typical with the starting settings. Edges absorb some neighboring BpSs.

### 12. Symbolize

Use **Unique Values** on `group` with your chosen colors, at about 40% transparency so the basemap shows through.

## Quality checks

- **Visual check:** zoom into a few areas with the raw BpS raster (group pixels highlighted) under the polygon outlines. Edges should follow the bulk of the pixels without stair steps.
- **Acreage check:** compare each group's smoothed acres to its raw pixel acres (pixel count × 0.2224 acres for 30 m cells; get counts from the attribute table or **Tabulate Area**).
  - **Roughly 90–110%:** typical for widespread groups that occur in large patches.
  - **Well above 100%:** the contour is absorbing neighboring types in mixed areas. Raise the contour level or reduce sigma.
  - **Well below 100%:** the group occurs as small or scattered patches that fall below the contour level or the minimum size. Lower the contour level, reduce sigma, or lower the minimum size, if those patches matter.
- **Overlaps:** after step 9, a **Pairwise Intersect** of the output with itself should return no areas between different groups.

## Tuning

- **Rounder, simpler shapes:** increase sigma (e.g., 120–150 m) and regenerate the kernel.
- **Capture narrow or scattered patches:** lower the contour level (e.g., 0.35) or reduce sigma (e.g., 75–90 m). Expect polygons to grow into neighboring types.
- **Group-specific settings:** each group can use its own sigma and contour level. Scattered types benefit from a smaller sigma or lower contour.
- **Map scale:**
  - **Small areas or large-scale maps:** use a smaller sigma, a smaller minimum size, and possibly no aggregation (cell factor 1 with a kernel built for 30 m cells; slower).
  - **Regional extents:** use a larger sigma and aggregation factor.
- **Simplify tolerance:** keep it well below sigma so shapes stay rounded. Increase it only if file size matters (e.g., web maps).

## Making a kernel file

The kernel is a normalized 2-D Gaussian extending 3 sigma from the center. It is the same as `terra::focalMat(r, sigma, "Gauss")` in R. Run this in the ArcGIS Pro Python window or any Python with numpy, setting `cell_m` to the cell size **after** aggregation:

```python
import numpy as np

def write_gauss_kernel(path, sigma_m, cell_m):
    half = int(np.floor(3 * sigma_m / cell_m))
    d = np.arange(-half, half + 1) * cell_m
    x, y = np.meshgrid(d, d)
    w = np.exp(-(x**2 + y**2) / (2 * sigma_m**2))
    w = w / w.sum()
    with open(path, "w") as f:
        f.write(f"{w.shape[1]} {w.shape[0]}\n")
        for row in w:
            f.write(" ".join(f"{v:.8f}" for v in row) + "\n")

write_gauss_kernel("gauss_kernel_90m_sigma100.txt", sigma_m=100, cell_m=90)
```

The first line of the file is the kernel width and height in cells; the following lines are the weights, row by row.

## Caveats

- **Not current vegetation:** BpS represents vegetation that may have been dominant prior to Euro-American settlement. Smoothed BpS polygons do not map current vegetation.
- **Edges are approximate:** polygon edges are the chosen neighborhood-share line, not an observed boundary. Use the polygons for planning-scale display and screening, not site-level decisions.
- **Software differences:** results from ArcGIS Pro and other software (e.g., the R `terra` + `isoband` equivalent) differ slightly because contour interpolation and simplification algorithms differ. Expect differences of a few percent in acres.
