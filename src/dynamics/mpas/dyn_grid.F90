module dyn_grid

!-------------------------------------------------------------------------------
!
! Define MPAS computational grids on the dynamics decomposition.
!
! Module responsibilities:
!
! . Provide the physics/dynamics coupler (in module phys_grid) with data for the
!   physics grid (cell centers) on the dynamics decomposition.
!
! . Create CAM grid objects that are used by the I/O functionality to read
!   data from an unstructured grid format to the dynamics data structures, and
!   to write from the dynamics data structures to unstructured grid format.  The
!   global column ordering for the unstructured grid is determined by the dycore.
!
! The MPAS grid is decomposed into "blocks" which contain the cells that are solved
! plus a set of halo cells.  The dycore assigns one block per task.
!
!-------------------------------------------------------------------------------

use shr_kind_mod,      only: r8 => shr_kind_r8
use spmd_utils,        only: iam, masterproc, mpicom, npes

use pmgrid,            only: plev, plevp
use physconst,         only: pi

use cam_logfile,       only: iulog
use cam_abortutils,    only: endrun

use pio,               only: file_desc_t, pio_global, pio_get_att

use cam_mpas_subdriver, only: domain_ptr, cam_mpas_init_phase3, cam_mpas_get_global_dims, &
                              cam_mpas_get_global_coords, cam_mpas_get_global_blocks,     &
                              cam_mpas_read_static, cam_mpas_compute_unit_vectors

use mpas_pool_routines, only: mpas_pool_get_subpool, mpas_pool_get_dimension, mpas_pool_get_array
use mpas_derived_types, only: mpas_pool_type


implicit none
private
save

integer, parameter :: dyn_decomp    = 101 ! cell center grid (this parameter is public to provide a dycore
                                          ! independent way to identify the physics grid on the dynamics
                                          ! decomposition)
integer, parameter :: cam_cell_decomp = 104 ! same grid decomp as dyn_decomp, but the grid definition
                                            ! uses ncol, lat, lon
integer, parameter :: edge_decomp   = 102 ! edge node grid
integer, parameter :: vertex_decomp = 103 ! vertex node grid
integer, parameter :: ptimelevels = 2

public :: &
   dyn_decomp, &
   ptimelevels, &
   dyn_grid_init, &
   get_block_bounds_d, &
   get_block_gcol_cnt_d, &
   get_block_gcol_d, &
   get_block_lvl_cnt_d, &
   get_block_levels_d, &
   get_block_owner_d, &
   get_gcol_block_d, &
   get_gcol_block_cnt_d, &
   get_horiz_grid_dim_d, &
   get_horiz_grid_d, &
   get_dyn_grid_parm, &
   get_dyn_grid_parm_real1d, &
   dyn_grid_get_elem_coords, &
   dyn_grid_get_colndx, &
   physgrid_copy_attributes_d

! vertical reference heights (m) in CAM top to bottom order.
real(r8) :: zw(plevp), zw_mid(plev)

integer ::      &
   maxNCells,   &    ! maximum number of cells for any task (nCellsSolve <= maxNCells)
   maxEdges,    &    ! maximum number of edges per cell
   nVertLevels       ! number of vertical layers (midpoints)

integer, pointer :: &
   nCellsSolve,     & ! number of cells that a task solves
   nEdgesSolve,     & ! number of edges (velocity) that a task solves
   nVerticesSolve,  & ! number of vertices (vorticity) that a task solves
   nVertLevelsSolve

real(r8), parameter :: rad2deg=180.0_r8/pi ! convert radians to degrees

! sphere_radius is a global attribute in the MPAS initial file.  It is needed to
! normalize the cell areas to a unit sphere.
real(r8) :: sphere_radius

! global grid data

integer ::      &
   nCells_g,    &    ! global number of cells/columns
   nEdges_g,    &    ! global number of edges
   nVertices_g       ! global number of vertices

integer, allocatable :: col_indices_in_block(:,:)  ! global column indices in each block
integer, allocatable :: num_col_per_block(:)       ! number of columns in each block
integer, allocatable :: global_blockid(:)          ! block id for each global column
integer, allocatable :: local_col_index(:)         ! local column index (in block) for each global column

real(r8), dimension(:), pointer :: lonCell_g       ! global cell longitudes
real(r8), dimension(:), pointer :: latCell_g       ! global cell latitudes
real(r8), dimension(:), pointer :: areaCell_g      ! global cell areas

!=========================================================================================
contains
!=========================================================================================

subroutine dyn_grid_init()

   ! Initialize grids on the dynamics decomposition and create associated
   ! grid objects for use by I/O utilities.  The current physics/dynamics
   ! coupling code requires constructing global fields for the cell center
   ! grid which is used by the physics parameterizations.

   use ref_pres,            only: ref_pres_init
   use std_atm_profile,     only: std_atm_pres
   use time_manager,        only: get_step_size

   use cam_initfiles,       only: initial_file_get_id

   use cam_history_support, only: add_vert_coord

   use constituents,        only: pcnst

   type(file_desc_t), pointer :: fh_ini

   integer  :: k, ierr
   integer  :: num_pr_lev       ! number of top levels using pure pressure representation
   real(r8) :: pref_edge(plevp) ! reference pressure at layer edges (Pa)
   real(r8) :: pref_mid(plev)   ! reference pressure at layer midpoints (Pa)

   character(len=*), parameter :: subname = 'dyn_grid::dyn_grid_init'
   !----------------------------------------------------------------------------

   ! Get filehandle for initial file
   fh_ini => initial_file_get_id()

   ! MPAS-A always requires at least one scalar (qv).  CAM has the same requirement
   ! and it is enforced by the configure script which sets the cpp macrop PCNST.
   call cam_mpas_init_phase3(fh_ini, pcnst, endrun)

   ! Read or compute all time-invariant fields for the MPAS-A dycore
   ! Time-invariant fields are stored in the MPAS mesh pool.  This call
   ! also sets the module data zw and zw_mid.
   call setup_time_invariant(fh_ini)

   ! Read the global sphere_radius attribute.  This is needed to normalize the cell areas.
   ierr = pio_get_att(fh_ini, pio_global, 'sphere_radius', sphere_radius)

   ! Compute reference pressures from reference heights.
   call std_atm_pres(zw, pref_edge)
   pref_mid = (pref_edge(1:plev) + pref_edge(2:plevp)) * 0.5_r8

   num_pr_lev = 0
   call ref_pres_init(pref_edge, pref_mid, num_pr_lev)

   ! Vertical coordinates for output streams
   call add_vert_coord('lev', plev,                       &
         'zeta level at vertical midpoints', 'm', zw_mid)
   call add_vert_coord('ilev', plevp,                     &
         'zeta level at vertical interfaces', 'm', zw)

   if (masterproc) then
      write(iulog,'(a)')' Reference Layer Locations: '
      write(iulog,'(a)')' index      height (m)              pressure (hPa) '
      do k= 1, plev
         write(iulog,9830) k, zw(k), pref_edge(k)/100._r8
         write(iulog,9840)    zw_mid(k), pref_mid(k)/100._r8
      end do
      write(iulog,9830) plevp, zw(plevp), pref_edge(plevp)/100._r8

9830  format(1x, i3, f15.4, 9x, f15.4)
9840  format(1x, 3x, 12x, f15.4, 9x, f15.4)
   end if

   ! Query global grid dimensions from MPAS
   call cam_mpas_get_global_dims(nCells_g, nEdges_g, nVertices_g, maxEdges, nVertLevels, maxNCells)

   ! Temporary global arrays needed by phys_grid_init
   allocate(lonCell_g(nCells_g))
   allocate(latCell_g(nCells_g))
   allocate(areaCell_g(nCells_g))
   call cam_mpas_get_global_coords(latCell_g, lonCell_g, areaCell_g)
   
   allocate(num_col_per_block(npes))
   allocate(col_indices_in_block(maxNCells,npes))
   allocate(global_blockid(nCells_g))
   allocate(local_col_index(nCells_g))
   call cam_mpas_get_global_blocks(num_col_per_block, col_indices_in_block, global_blockID, local_col_index)
   
   ! Define the dynamics grids on the dynamics decompostion.  The cell
   ! centered grid is used by the physics parameterizations.  The physics
   ! decomposition of the cell centered grid is defined in phys_grid_init.
   call define_cam_grids()
   
end subroutine dyn_grid_init

!=========================================================================================

subroutine get_block_bounds_d(block_first, block_last)

   ! Return first and last indices used in global block ordering.
   ! The indexing is 1-based.

   integer, intent(out) :: block_first  ! first global index used for blocks
   integer, intent(out) :: block_last   ! last global index used for blocks
   !----------------------------------------------------------------------------

   ! MPAS assigns 1 block per task.

   block_first = 1
   block_last = npes

end subroutine get_block_bounds_d

!=========================================================================================

integer function get_block_gcol_cnt_d(blockid)

   ! Return the number of dynamics columns in the block with the specified
   ! global block ID.  The blockid can be for a block owned by any MPI
   ! task.

   integer, intent(in) :: blockid
   !----------------------------------------------------------------------------

   get_block_gcol_cnt_d = num_col_per_block(blockid)

end function get_block_gcol_cnt_d

!=========================================================================================

subroutine get_block_gcol_d(blockid, asize, cdex)

   ! Return list of global dynamics column indices in the block with the
   ! specified global block ID.  The blockid can be for a block owned by
   ! any MPI task.

   integer, intent(in) :: blockid      ! global block id
   integer, intent(in) :: asize        ! array size

   integer, intent(out):: cdex(asize)  ! global column indices

   integer :: icol

   character(len=*), parameter :: subname = 'dyn_grid::get_block_gcol_d'
   !----------------------------------------------------------------------------

   if (asize < num_col_per_block(blockid)) then
      write(iulog,*) subname//': array size too small: asize, num_col_per_block=', &
         asize, num_col_per_block(blockid)
      call endrun(subname//': array size too small')
   end if

   do icol = 1, num_col_per_block(blockid)
      cdex(icol) = col_indices_in_block(icol, blockid)
   end do
   do icol = num_col_per_block(blockid)+1, asize
      cdex(icol) = 0
   end do

end subroutine get_block_gcol_d
   
!=========================================================================================
   
integer function get_block_lvl_cnt_d(blockid, bcid)

   ! Returns the number of levels in the specified column of the specified block.
   ! If column includes surface fields, then it is defined to also
   ! include level 0.

   integer, intent(in) :: blockid  ! global block id
   integer, intent(in) :: bcid     ! column index within block
   !----------------------------------------------------------------------------

   ! All blocks have the same number of levels.
   get_block_lvl_cnt_d = plevp

end function get_block_lvl_cnt_d

!=========================================================================================

subroutine get_block_levels_d(blockid, bcid, lvlsiz, levels)

   ! Returns the level indices in the column of the specified global block.
   ! For MPAS decomposition all columns in a block contain complete vertical grid.

   integer, intent(in) :: blockid  ! global block id
   integer, intent(in) :: bcid     ! column index within block
   integer, intent(in) :: lvlsiz   ! dimension of levels array

   integer, intent(out) :: levels(lvlsiz) ! level indices for block

   integer :: k
   character(len=128) :: errmsg

   character(len=*), parameter :: subname = 'dyn_grid::get_block_levels_d'
   !----------------------------------------------------------------------------

   if ( lvlsiz < plev + 1 ) then
      write(errmsg,*) ': levels array not large enough (', lvlsiz,' < ',plev + 1,')'
      call endrun( subname // trim(errmsg) )
   else
      do k = 0, plev
         levels(k+1) = k
      end do
      do k = plev+2, lvlsiz
         levels(k) = -1
      end do
   end if

end subroutine get_block_levels_d

!=========================================================================================

integer function get_gcol_block_cnt_d(gcol)

   ! Return number of blocks containing data for the vertical column
   ! with the specified global column index.

   integer, intent(in) :: gcol     ! global column index
   !----------------------------------------------------------------------------

   ! Each global column is solved in just one block.  The blocks where that column may
   ! be in a halo cell are not counted.
   get_gcol_block_cnt_d = 1

end function get_gcol_block_cnt_d

!=========================================================================================

subroutine get_gcol_block_d(gcol, cnt, blockid, bcid)

   ! Return global block index and local column index for a global column index.
   ! This routine can be called for global columns that are not owned by
   ! the calling task.

   integer, intent(in) :: gcol     ! global column index
   integer, intent(in) :: cnt      ! size of blockid and bcid arrays

   integer, intent(out) :: blockid(cnt) ! block index
   integer, intent(out) :: bcid(cnt)    ! column index within block

   integer :: j

   character(len=*), parameter :: subname = 'dyn_grid::get_gcol_block_d'
   !----------------------------------------------------------------------------

   if ( cnt < 1 ) then
      write(iulog,*) subname//': arrays not large enough: cnt= ', cnt
      call endrun( subname // ': arrays not large enough' )
   end if

   ! Each global column is solved in just one block.
   blockid(1) = global_blockid(gcol)
   bcid(1) = local_col_index(gcol)

   do j=2,cnt
      blockid(j) = -1
      bcid(j)    = -1
   end do

end subroutine get_gcol_block_d

!=========================================================================================

integer function get_block_owner_d(blockid)

   ! Return the ID of the task that owns the indicated global block.
   ! Assume that task IDs are 0-based as in MPI.

   integer, intent(in) :: blockid  ! global block id
   !----------------------------------------------------------------------------

   ! MPAS assigns one block per task.
   get_block_owner_d = (blockid - 1)

end function get_block_owner_d

!=========================================================================================

subroutine get_horiz_grid_dim_d(hdim1_d, hdim2_d)

   ! Return declared horizontal dimensions of global grid.
   ! For non-lon/lat grids, declare grid to be one-dimensional,
   ! i.e., (ngcols,1) where ngcols is total number of columns in grid.

   integer, intent(out) :: hdim1_d             ! first horizontal dimension
   integer, intent(out), optional :: hdim2_d   ! second horizontal dimension
   !----------------------------------------------------------------------------

   hdim1_d = nCells_g

   if( present(hdim2_d) ) hdim2_d = 1

end subroutine get_horiz_grid_dim_d

!=========================================================================================

subroutine get_horiz_grid_d(nxy, clat_d_out, clon_d_out, area_d_out, &
       wght_d_out, lat_d_out, lon_d_out)

   ! Return global arrays of latitude and longitude (in radians), column
   ! surface area (in radians squared) and surface integration weights for
   ! columns in physics grid (cell centers)

   integer, intent(in) :: nxy                     ! array sizes

   real(r8), intent(out), optional :: clat_d_out(:) ! column latitudes (radians)
   real(r8), intent(out), optional :: clon_d_out(:) ! column longitudes (radians)
   real(r8), intent(out), target, optional :: area_d_out(:) ! sum to 4*pi (radians^2)
   real(r8), intent(out), target, optional :: wght_d_out(:) ! normalized to sum to 4*pi
   real(r8), intent(out), optional :: lat_d_out(:)  ! column latitudes (degrees)
   real(r8), intent(out), optional :: lon_d_out(:)  ! column longitudes (degrees)

   character(len=*), parameter :: subname = 'dyn_grid::get_horiz_grid_d'
   !----------------------------------------------------------------------------

   if ( nxy /= nCells_g ) then
      write(iulog,*) subname//': incorrect number of cells: nxy, nCells_g= ', &
         nxy, nCells_g
      call endrun(subname//': incorrect number of cells')
   end if

   if ( present( clat_d_out ) ) then
      clat_d_out(:) = latCell_g(:)
   end if

   if ( present( clon_d_out ) ) then
      clon_d_out(:) = lonCell_g(:)
   end if

   if ( present( area_d_out ) ) then
      area_d_out(:) = areaCell_g(:) / (sphere_radius**2)
   end if

   if ( present( wght_d_out ) ) then
      wght_d_out(:) = areaCell_g(:) / (sphere_radius**2)
   end if

   if ( present( lat_d_out ) ) then
      lat_d_out(:) = latCell_g(:) * rad2deg
   end if

   if ( present( lon_d_out ) ) then
      lon_d_out(:) = lonCell_g(:) * rad2deg
   end if

end subroutine get_horiz_grid_d

!=========================================================================================

subroutine physgrid_copy_attributes_d(gridname, grid_attribute_names)

   ! Create list of attributes for the physics grid that should be copied
   ! from the corresponding grid object on the dynamics decomposition

   use cam_grid_support, only: max_hcoordname_len

   character(len=max_hcoordname_len),          intent(out) :: gridname
   character(len=max_hcoordname_len), pointer, intent(out) :: grid_attribute_names(:)
   !----------------------------------------------------------------------------


   ! Do not let the physics grid copy the mpas_cell "area" attribute because
   ! it is using a different dimension name.
   gridname = 'mpas_cell'
   allocate(grid_attribute_names(0))

end subroutine physgrid_copy_attributes_d

!=========================================================================================

function get_dyn_grid_parm_real1d(name) result(rval)

   ! This routine is not used for unstructured grids, but still needed as a
   ! dummy interface to satisfy references (for linking executable) from mo_synoz.F90
   ! and phys_gmean.F90.

   character(len=*), intent(in) :: name
   real(r8), pointer :: rval(:)

   character(len=*), parameter :: subname = 'dyn_grid::get_dyn_grid_parm_real1d'
   !----------------------------------------------------------------------------

   if (name .eq. 'w') then
      call endrun(subname//': w not defined')
   else if( name .eq. 'clat') then
      call endrun(subname//': clat not supported, use get_horiz_grid_d')
   else if( name .eq. 'latdeg') then
      call endrun(subname//': latdeg not defined')
   else
      nullify(rval)
   end if

end function get_dyn_grid_parm_real1d

!=========================================================================================

integer function get_dyn_grid_parm(name) result(ival)

   ! This function is in the process of being deprecated, but is still needed
   ! as a dummy interface to satisfy external references from some chemistry routines.

   character(len=*), intent(in) :: name
   !----------------------------------------------------------------------------

   if (name == 'plat') then
      ival = 1
   else if (name == 'plon') then
      ival = nCells_g
   else if(name == 'plev') then
      ival = plev
   else	
      ival = -1
   end if

end function get_dyn_grid_parm

!=========================================================================================

subroutine dyn_grid_get_colndx(igcol, ncols, owners, col, lbk )

   ! For each global column index return the owning task.  If the column is owned
   ! by this task, then also return the local block number and column index in that
   ! block.

   integer, intent(in)  :: ncols
   integer, intent(in)  :: igcol(ncols)
   integer, intent(out) :: owners(ncols)
   integer, intent(out) :: col(ncols)
   integer, intent(out) :: lbk(ncols)

   integer  :: i
   integer :: blockid(1), bcid(1)
   !----------------------------------------------------------------------------

   do i = 1,ncols
      
      call  get_gcol_block_d(igcol(i), 1, blockid, bcid)
      owners(i) = get_block_owner_d(blockid(1))
  
      if ( iam==owners(i) ) then
         lbk(i) = 1         ! only 1 block per task
         col(i) = bcid(1)
      else
         lbk(i) = -1
         col(i) = -1
      end if
  
   end do

end subroutine dyn_grid_get_colndx

!=========================================================================================

subroutine dyn_grid_get_elem_coords(ie, rlon, rlat, cdex )

   ! Returns the latitude and longitude coordinates, as well as global IDs,
   ! for the columns in a block.

   integer, intent(in) :: ie ! block index

   real(r8),optional, intent(out) :: rlon(:) ! longitudes of the columns in the block
   real(r8),optional, intent(out) :: rlat(:) ! latitudes of the columns in the block
   integer, optional, intent(out) :: cdex(:) ! global column index

   character(len=*), parameter :: subname = 'dyn_grid::dyn_grid_get_elem_coords'
   !----------------------------------------------------------------------------

   ! This routine is called for history output when local time averaging is requested
   ! for a field on a dynamics decomposition.  The code in hbuf_accum_addlcltime appears
   ! to also assume that the field is on the physics grid since there is no argument
   ! passed to specify which dynamics grid the coordinates are for.
   
   call endrun(subname//': not implemented for the MPAS grids')

end subroutine dyn_grid_get_elem_coords

!=========================================================================================
! Private routines.
!=========================================================================================

subroutine setup_time_invariant(fh_ini)

   ! Initialize all time-invariant fields needed by the MPAS-Atmosphere dycore,
   ! by reading these fields from the initial file.

   use mpas_rbf_interpolation, only : mpas_rbf_interp_initialize
   use mpas_vector_reconstruction, only : mpas_init_reconstruct

   ! Arguments
   type(file_desc_t), pointer :: fh_ini

   ! Local variables
   type(mpas_pool_type),   pointer :: meshPool
   real(r8), pointer     :: rdzw(:)
   real(r8), allocatable :: dzw(:)

   integer :: k, kk

   character(len=*), parameter :: routine = 'dyn_grid::setup_time_invariant'
   !----------------------------------------------------------------------------

   ! Read time-invariant fields
   call cam_mpas_read_static(fh_ini, endrun)

   ! Compute unit vectors giving the local north and east directions as well as
   ! the unit normal vector for edges
   call cam_mpas_compute_unit_vectors()

   ! Access dimensions that are made public via this module
   call mpas_pool_get_subpool(domain_ptr % blocklist % structs, 'mesh', meshPool)
   call mpas_pool_get_dimension(meshPool, 'nCellsSolve', nCellsSolve)
   call mpas_pool_get_dimension(meshPool, 'nEdgesSolve', nEdgesSolve)
   call mpas_pool_get_dimension(meshPool, 'nVerticesSolve', nVerticesSolve)
   call mpas_pool_get_dimension(meshPool, 'nVertLevels', nVertLevelsSolve) ! MPAS always solves over the full column

   ! check that number of vertical layers matches MPAS grid data
   if (plev /= nVertLevelsSolve) then
      write(iulog,*) routine//': ERROR: number of levels in IC file does not match plev: file, plev=', &
                     nVertLevelsSolve, plev
      call endrun(routine//': ERROR: number of levels in IC file does not match plev.')
   end if

   ! Initialize fields needed for reconstruction of cell-centered winds from edge-normal winds
   ! Note: This same pair of calls happens a second time later in the initialization of
   !       the MPAS-A dycore (in atm_mpas_init_block), but the redundant calls do no harm
   call mpas_rbf_interp_initialize(meshPool)
   call mpas_init_reconstruct(meshPool)

   ! Compute the zeta coordinate at layer interfaces and midpoints.  Store
   ! in arrays using CAM vertical index order (top to bottom of atm) for use
   ! in CAM coordinate objects.
   call mpas_pool_get_array(meshPool, 'rdzw', rdzw)

   allocate(dzw(plev))
   dzw = 1._r8 / rdzw
   zw(plev+1) = 0._r8
   do k = plev, 1, -1
      kk = plev - k + 1
      zw(k) = zw(k+1) + dzw(kk)
      zw_mid(k) = 0.5_r8 * (zw(k+1) + zw(k))
   end do

   deallocate(dzw)

end subroutine setup_time_invariant

!=========================================================================================

subroutine define_cam_grids()

   ! Define the dynamics grids on the dynamics decompostion.  The 'physics'
   ! grid contains the same nodes as the dynamics cell center grid, but is
   ! on the physics decomposition and is defined in phys_grid_init.
   !
   ! Note that there are two versions of cell center grid defined here.
   ! The 'mpas_cell' grid uses 'nCells' rather than 'ncol' as the dimension
   ! name and 'latCell', 'lonCell' rather than 'lat' and 'lon' as the
   ! coordinate names.  This allows us to read the same initial file that
   ! is used by the standalone MPAS-A model.  The second cell center grid
   ! is called 'cam_cell' and uses the standard CAM names: ncol, lat, and
   ! lon.  This grid allows us to read the PHIS field from the CAM topo
   ! file.  There is just a single version of the grids to read data on the
   ! cell edge and vertex locations.  These are used to read data from the
   ! initial file and to write data from the dynamics decomposition to the
   ! CAM history file.

   use cam_grid_support, only: horiz_coord_t, horiz_coord_create, iMap
   use cam_grid_support, only: cam_grid_register, cam_grid_attribute_register
 
   ! Local variables
   integer :: i, j

   type(horiz_coord_t), pointer     :: lat_coord
   type(horiz_coord_t), pointer     :: lon_coord
   integer(iMap),       allocatable :: gidx(:)        ! global indices
   integer(iMap),       pointer     :: grid_map(:,:)

   type(mpas_pool_type),   pointer :: meshPool

   integer,  dimension(:), pointer :: indexToCellID ! global indices of cell centers
   real(r8), dimension(:), pointer :: latCell   ! cell center latitude (radians)
   real(r8), dimension(:), pointer :: lonCell   ! cell center longitude (radians)
   real(r8), dimension(:), pointer :: areaCell  ! cell areas in m^2

   integer,  dimension(:), pointer :: indexToEdgeID ! global indices of edge nodes
   real(r8), dimension(:), pointer :: latEdge   ! edge node latitude (radians)
   real(r8), dimension(:), pointer :: lonEdge   ! edge node longitude (radians)

   integer,  dimension(:), pointer :: indexToVertexID ! global indices of vertex nodes
   real(r8), dimension(:), pointer :: latVertex ! vertex node latitude (radians)
   real(r8), dimension(:), pointer :: lonVertex ! vertex node longitude (radians)
   !----------------------------------------------------------------------------

   call mpas_pool_get_subpool(domain_ptr % blocklist % structs, 'mesh', meshPool)

   !-------------------------------------------------------------!
   ! Construct coordinate and grid objects for cell center grid. !
   !-------------------------------------------------------------!

   call mpas_pool_get_array(meshPool, 'indexToCellID', indexToCellID)
   call mpas_pool_get_array(meshPool, 'latCell', latCell)
   call mpas_pool_get_array(meshPool, 'lonCell', lonCell)
   call mpas_pool_get_array(meshPool, 'areaCell', areaCell)

   allocate(gidx(nCellsSolve))
   gidx = indexToCellID(1:nCellsSolve)

   lat_coord => horiz_coord_create('latCell', 'nCells', nCells_g, 'latitude',      &
          'degrees_north', 1, nCellsSolve, latCell(1:nCellsSolve)*rad2deg, map=gidx)
   lon_coord => horiz_coord_create('lonCell', 'nCells', nCells_g, 'longitude',     &
          'degrees_east', 1, nCellsSolve, lonCell(1:nCellsSolve)*rad2deg, map=gidx)
 
   ! Map for cell centers grid
   allocate(grid_map(3, nCellsSolve))
   do i = 1, nCellsSolve
      grid_map(1, i) = i
      grid_map(2, i) = 1
      grid_map(3, i) = gidx(i)
   end do

   ! cell center grid for I/O using MPAS names
   call cam_grid_register('mpas_cell', dyn_decomp, lat_coord, lon_coord,     &
          grid_map, block_indexed=.false., unstruct=.true.)

   ! create new coordinates and grid using CAM names
   lat_coord => horiz_coord_create('lat', 'ncol', nCells_g, 'latitude',      &
          'degrees_north', 1, nCellsSolve, latCell(1:nCellsSolve)*rad2deg, map=gidx)
   lon_coord => horiz_coord_create('lon', 'ncol', nCells_g, 'longitude',     &
          'degrees_east', 1, nCellsSolve, lonCell(1:nCellsSolve)*rad2deg, map=gidx)
   call cam_grid_register('cam_cell', cam_cell_decomp, lat_coord, lon_coord, &
          grid_map, block_indexed=.false., unstruct=.true.)

   ! gidx can be deallocated.  Values are copied into the coordinate and attribute objects.
   deallocate(gidx)

   ! grid_map memory cannot be deallocated.  The cam_filemap_t object just points
   ! to it.  Pointer can be disassociated.
   nullify(grid_map) ! Map belongs to grid now

   ! pointers to coordinate objects can be nullified.  Memory is now pointed to by the
   ! grid object.
   nullify(lat_coord)
   nullify(lon_coord)

   !-----------------------------------------------------------!
   ! Construct coordinate and grid objects for edge node grid. !
   !-----------------------------------------------------------!

   call mpas_pool_get_array(meshPool, 'indexToEdgeID', indexToEdgeID)
   call mpas_pool_get_array(meshPool, 'latEdge', latEdge)
   call mpas_pool_get_array(meshPool, 'lonEdge', lonEdge)

   allocate(gidx(nEdgesSolve))
   gidx = indexToEdgeID(1:nEdgesSolve)

   lat_coord => horiz_coord_create('latEdge', 'nEdges', nEdges_g, 'latitude',      &
          'degrees_north', 1, nEdgesSolve, latEdge(1:nEdgesSolve)*rad2deg, map=gidx)
   lon_coord => horiz_coord_create('lonEdge', 'nEdges', nEdges_g, 'longitude',     &
          'degrees_east', 1, nEdgesSolve, lonEdge(1:nEdgesSolve)*rad2deg, map=gidx)
 
   ! Map for edge node grid
   allocate(grid_map(3, nEdgesSolve))
   do i = 1, nEdgesSolve
      grid_map(1, i) = i
      grid_map(2, i) = 1
      grid_map(3, i) = gidx(i)
   end do

   ! Edge node grid object
   call cam_grid_register('mpas_edge', edge_decomp, lat_coord, lon_coord,     &
          grid_map, block_indexed=.false., unstruct=.true.)

   deallocate(gidx)
   nullify(grid_map)
   nullify(lat_coord)
   nullify(lon_coord)

   !-------------------------------------------------------------!
   ! Construct coordinate and grid objects for vertex node grid. !
   !-------------------------------------------------------------!

   call mpas_pool_get_array(meshPool, 'indexToVertexID', indexToVertexID)
   call mpas_pool_get_array(meshPool, 'latVertex', latVertex)
   call mpas_pool_get_array(meshPool, 'lonVertex', lonVertex)

   allocate(gidx(nVerticesSolve))
   gidx = indexToVertexID(1:nVerticesSolve)

   lat_coord => horiz_coord_create('latVertex', 'nVertices', nVertices_g, 'latitude',      &
          'degrees_north', 1, nVerticesSolve, latVertex(1:nVerticesSolve)*rad2deg, map=gidx)
   lon_coord => horiz_coord_create('lonVertex', 'nVertices', nVertices_g, 'longitude',     &
          'degrees_east', 1, nVerticesSolve, lonVertex(1:nVerticesSolve)*rad2deg, map=gidx)
 
   ! Map for vertex node grid
   allocate(grid_map(3, nVerticesSolve))
   do i = 1, nVerticesSolve
      grid_map(1, i) = i
      grid_map(2, i) = 1
      grid_map(3, i) = gidx(i)
   end do

   ! Vertex node grid object
   call cam_grid_register('mpas_vertex', vertex_decomp, lat_coord, lon_coord,     &
          grid_map, block_indexed=.false., unstruct=.true.)

   deallocate(gidx)
   nullify(grid_map)
   nullify(lat_coord)
   nullify(lon_coord)
   
end subroutine define_cam_grids

end module dyn_grid
