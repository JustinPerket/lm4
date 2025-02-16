!***********************************************************************
!*                   GNU Lesser General Public License
!*
!* This file is part of the GFDL Land Model 4 (LM4).
!*
!* LM4 is free software: you can redistribute it and/or modify it under
!* the terms of the GNU Lesser General Public License as published by
!* the Free Software Foundation, either version 3 of the License, or (at
!* your option) any later version.
!*
!* LM4 is distributed in the hope that it will be useful, but WITHOUT
!* ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
!* FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
!* for more details.
!*
!* You should have received a copy of the GNU Lesser General Public
!* License along with LM4.  If not, see <http://www.gnu.org/licenses/>.
!***********************************************************************
module vegn_harvesting_mod

use fms_mod, only : string, error_mesg, FATAL, NOTE, &
     mpp_pe, &
     check_nml_error, stdlog, mpp_root_pe
use mpp_mod, only: input_nml_file
use vegn_data_mod, only : N_LU_TYPES, LU_PAST, LU_CROP, LU_NTRL, LU_SCND, &
     HARV_POOL_PAST, HARV_POOL_CROP, HARV_POOL_CLEARED, HARV_POOL_WOOD_FAST, &
     HARV_POOL_WOOD_MED, HARV_POOL_WOOD_SLOW, &
     agf_bs, fsc_liv, fsc_froot, fsc_wood
use soil_tile_mod, only : soil_tile_type
use vegn_tile_mod, only : vegn_tile_type, vegn_tile_LAI
use vegn_cohort_mod, only : vegn_cohort_type, update_biomass_pools
use soil_carbon_mod, only: soil_carbon_option, &
     SOILC_CENTURY, SOILC_CENTURY_BY_LAYER, SOILC_CORPSE
use land_data_mod, only: log_version

implicit none
private

! ==== public interface ======================================================
public :: vegn_harvesting_init
public :: vegn_harvesting_end

public :: vegn_harvesting

public :: vegn_graze_pasture
public :: vegn_harvest_cropland
public :: vegn_cut_forest
! ==== end of public interface ===============================================

! ==== module constants ======================================================
character(len=*), parameter :: module_name = 'vegn_harvesting_mod'
#include "../shared/version_variable.inc"
real, parameter :: ONETHIRD = 1.0/3.0
integer, parameter :: DAILY = 1, ANNUAL = 2

! ==== module data ===========================================================

! ---- namelist variables ----------------------------------------------------
logical, public, protected :: do_harvesting = .TRUE.  ! if true, then harvesting of crops and pastures is done
real :: grazing_intensity      = 0.25    ! fraction of leaf biomass removed by grazing annually.
  ! NOTE that for daily grazing, grazing_intensity/365 fraction of leaf biomass is removed 
  ! every day. E.g. if the desired intensity is 1% of leaves per day, set grazing_intensity 
  ! to 3.65
real :: grazing_residue        = 0.1     ! fraction of the grazed biomass transferred into soil pools
character(16) :: grazing_frequency = 'annual' ! or 'daily'
real :: min_lai_for_grazing    = 0.0     ! no grazing if LAI lower than this threshold
  ! NOTE that in CORPSE mode regardless of the grazing frequency soil carbon input from
  ! grazing still goes to intermediate pools, and then it is transferred from
  ! these pools to soil/litter carbon pools with constant rates over the next year.
  ! In CENTURY mode grazing residue is deposited to soil directly in case of daily 
  ! grazing frequency; still goes through intermediate pools in case of annual grazing.
real :: frac_wood_wasted_harv  = 0.25    ! fraction of wood wasted while harvesting
real :: frac_wood_wasted_clear = 0.25    ! fraction of wood wasted while clearing land for pastures or crops
logical :: waste_below_ground_wood = .TRUE. ! If true, all the wood below ground (1-agf_bs fraction of bwood
        ! and bsw) is wasted. Old behavior assumed this to be FALSE.
real :: frac_wood_fast         = ONETHIRD ! fraction of wood consumed fast
real :: frac_wood_med          = ONETHIRD ! fraction of wood consumed with medium speed
real :: frac_wood_slow         = ONETHIRD ! fraction of wood consumed slowly
real :: crop_seed_density      = 0.1     ! biomass of seeds left after crop harvesting, kg/m2
namelist/harvesting_nml/ do_harvesting, grazing_intensity, grazing_residue, &
     grazing_frequency, min_lai_for_grazing, &
     frac_wood_wasted_harv, frac_wood_wasted_clear, waste_below_ground_wood, &
     frac_wood_fast, frac_wood_med, frac_wood_slow, &
     crop_seed_density

integer :: grazing_freq = -1 ! inidicator of grazing frequency (ANNUAL or DAILY)

contains ! ###################################################################

! ============================================================================
subroutine vegn_harvesting_init
  integer :: unit, ierr, io

  call log_version(version, module_name, &
  __FILE__)

  read (input_nml_file, nml=harvesting_nml, iostat=io)
  ierr = check_nml_error(io, 'harvesting_nml')

  if (mpp_pe() == mpp_root_pe()) then
     unit=stdlog()
     write(unit, nml=harvesting_nml)
  endif

  if (frac_wood_fast+frac_wood_med+frac_wood_slow/=1.0) then
     call error_mesg('vegn_harvesting_init', &
          'sum of frac_wood_fast, frac_wood_med, and frac_wood_slow must be 1.0',&
          FATAL)
  endif
  ! parse the grazing frequency parameter
  select case(grazing_frequency)
  case('annual')
     grazing_freq = ANNUAL
  case('daily')
     grazing_freq = DAILY
     ! scale grazing intensity for daily frequency
     grazing_intensity = grazing_intensity/365.0
  case default
     call error_mesg('vegn_harvesting_init','grazing_frequency must be "annual" or "daily"',FATAL)
  end select
end subroutine vegn_harvesting_init


! ============================================================================
subroutine vegn_harvesting_end
end subroutine vegn_harvesting_end


! ============================================================================
! harvest vegetation in a tile
subroutine vegn_harvesting(vegn, soil, end_of_year, end_of_month, end_of_day)
  type(vegn_tile_type), intent(inout) :: vegn
  type(soil_tile_type), intent(inout) :: soil
  logical, intent(in) :: end_of_year, end_of_month, end_of_day ! indicators of respective period boundaries

  if (.not.do_harvesting) return ! do nothing if no harvesting requested

  select case(vegn%landuse)
  case(LU_PAST)  ! pasture
     if ((end_of_day  .and. grazing_freq==DAILY).or. &
         (end_of_year .and. grazing_freq==ANNUAL)) then
        call vegn_graze_pasture (vegn, soil)
     endif
  case(LU_CROP)  ! crop
     if (end_of_year) call vegn_harvest_cropland (vegn)
  end select
end subroutine


! ============================================================================
subroutine vegn_graze_pasture(vegn, soil)
  type(vegn_tile_type), intent(inout) :: vegn
  type(soil_tile_type), intent(inout) :: soil

  ! ---- local vars
  real ::  bdead0, balive0, bleaf0, bfroot0, btotal0 ! initial combined biomass pools
  real ::  bdead1, balive1, bleaf1, bfroot1, btotal1 ! updated combined biomass pools
  type(vegn_cohort_type), pointer :: cc ! shorthand for the current cohort
  integer :: i
  real :: deltafast, deltaslow

  if ( vegn_tile_LAI(vegn) .lt. min_lai_for_grazing ) return

  balive0 = 0 ; balive1 = 0
  bdead0  = 0 ; bdead1  = 0
  bleaf0  = 0 ; bleaf1  = 0
  bfroot0 = 0 ; bfroot1 = 0

  ! update biomass pools for each cohort according to harvested fraction
  do i = 1,vegn%n_cohorts
     cc=>vegn%cohorts(i)
     ! calculate total biomass pools for the patch
     balive0 = balive0 + cc%bl + cc%blv + cc%br
     bleaf0  = bleaf0  + cc%bl + cc%blv
     bfroot0 = bfroot0 + cc%br
     bdead0  = bdead0  + cc%bwood + cc%bsw
     ! only potential leaves are consumed
     vegn%harv_pool(HARV_POOL_PAST) = vegn%harv_pool(HARV_POOL_PAST) + &
          cc%bliving*cc%Pl*grazing_intensity*(1-grazing_residue) ;
     cc%bliving = cc%bliving - cc%bliving*cc%Pl*grazing_intensity;

     ! redistribute leftover biomass between biomass pools
     call update_biomass_pools(cc);

     ! calculate new combined vegetation biomass pools
     balive1 = balive1 + cc%bl + cc%blv + cc%br
     bleaf1  = bleaf1  + cc%bl + cc%blv
     bfroot1 = bfroot1 + cc%br
     bdead1  = bdead1  + cc%bwood + cc%bsw
  enddo
  btotal0 = balive0 + bdead0
  btotal1 = balive1 + bdead1

  ! update intermediate soil carbon pools
  select case(soil_carbon_option)
  case(SOILC_CENTURY,SOILC_CENTURY_BY_LAYER)
     deltafast = (fsc_liv*(balive0-balive1)+fsc_wood*(bdead0-bdead1))*grazing_residue
     deltaslow = ((1-fsc_liv)*(balive0-balive1)+ (1-fsc_wood)*(bdead0-bdead1))*grazing_residue
     if (grazing_freq==DAILY) then
        ! put carbon directly in the soil pools
        soil%fast_soil_C(1) = soil%fast_soil_C(1) + deltafast
        soil%slow_soil_C(1) = soil%slow_soil_C(1) + deltaslow
     else
        ! put carbon into intermediate pools for gradual transfer to soil
        vegn%fsc_pool_bg = vegn%fsc_pool_bg + deltafast
        vegn%ssc_pool_bg = vegn%ssc_pool_bg + deltaslow
     endif
  case(SOILC_CORPSE)
     vegn%leaflitter_buffer_ag = vegn%leaflitter_buffer_ag + &
          (bleaf0-bleaf1)*grazing_residue;
     vegn%coarsewoodlitter_buffer_ag = vegn%coarsewoodlitter_buffer_ag + &
           agf_bs*(bdead0-bdead1)*grazing_residue
     vegn%fsc_pool_ag = vegn%fsc_pool_ag + &
          (fsc_liv*(bleaf0-bleaf1)+agf_bs*fsc_wood*(bdead0-bdead1))*grazing_residue;
     vegn%ssc_pool_ag = vegn%ssc_pool_ag + &
          ((1-fsc_liv)*(bleaf0-bleaf1)+ agf_bs*(1-fsc_wood)*(bdead0-bdead1))*grazing_residue;
     vegn%fsc_pool_bg=vegn%fsc_pool_bg + grazing_residue*(fsc_froot*(bfroot0-bfroot1) + fsc_liv*(bleaf0-bleaf1)+(1-agf_bs)*fsc_wood*(bdead0-bdead1))
     vegn%ssc_pool_bg = vegn%ssc_pool_bg + grazing_residue*((1-fsc_froot)*(bfroot0-bfroot1) + (1-fsc_liv)*(bleaf0-bleaf1)+ (1-agf_bs)*(1-fsc_wood)*(bdead0-bdead1))
  case default
     call error_mesg('vegn_graze_pasture','The value of soil_carbon_option is invalid. This should never happen. Contact developer.',FATAL)
  end select
end subroutine vegn_graze_pasture


! ================================================================================
subroutine vegn_harvest_cropland(vegn)
  type(vegn_tile_type), intent(inout) :: vegn

  ! ---- local vars
  type(vegn_cohort_type), pointer :: cc ! pointer to the current cohort
  real :: fraction_harvested;    ! fraction of biomass harvested this time
  real :: bdead, balive, btotal; ! combined biomass pools
  integer :: i

  balive = 0 ; bdead = 0
  ! calculate initial combined biomass pools for the patch
  do i = 1, vegn%n_cohorts
     cc=>vegn%cohorts(i)
     ! calculate total biomass pools for the patch
     balive = balive + cc%bl + cc%blv + cc%br
     bdead  = bdead  + cc%bwood + cc%bsw
  enddo
  btotal = balive+bdead;

  ! calculate harvested fraction: cut everything down to seed level
  if(btotal > 0.0) then
    fraction_harvested = MIN(MAX((btotal-crop_seed_density)/btotal,0.0),1.0);
  else
    fraction_harvested = 0.0
  endif

  ! update biomass pools for each cohort according to harvested fraction
  do i = 1, vegn%n_cohorts
     cc=>vegn%cohorts(i)
     ! use for harvest only aboveg round living biomass and waste the correspondent below living and wood
     vegn%harv_pool(HARV_POOL_CROP) = vegn%harv_pool(HARV_POOL_CROP) + &
          cc%bliving*(cc%Pl + cc%Psw*agf_bs)*fraction_harvested
     select case (soil_carbon_option)
     case (SOILC_CENTURY, SOILC_CENTURY_BY_LAYER)
        vegn%fsc_pool_bg = vegn%fsc_pool_bg + fraction_harvested*(fsc_liv*cc%bliving*cc%Pr + &
             fsc_wood*(cc%bwood + cc%bliving*cc%Psw*(1-agf_bs)))
        vegn%ssc_pool_bg = vegn%ssc_pool_bg + fraction_harvested*((1-fsc_liv)*cc%bliving*cc%Pr + &
             (1-fsc_wood)*(cc%bwood + cc%bliving*cc%Psw*(1-agf_bs)))
     case (SOILC_CORPSE)
        vegn%coarsewoodlitter_buffer_ag=vegn%coarsewoodlitter_buffer_ag + fraction_harvested*agf_bs*cc%bwood

        vegn%fsc_pool_ag = vegn%fsc_pool_ag + fraction_harvested*( &
             agf_bs*fsc_wood*(cc%bwood));
        vegn%ssc_pool_ag = vegn%ssc_pool_ag + fraction_harvested*( &
             agf_bs*(1-fsc_wood)*(cc%bwood));
        vegn%fsc_pool_bg = vegn%fsc_pool_bg + fraction_harvested*(fsc_froot*cc%bliving*cc%Pr + &
               (1-agf_bs)*fsc_wood*(cc%bwood + cc%bliving*cc%Psw))
        vegn%ssc_pool_bg = vegn%ssc_pool_bg + fraction_harvested*((1-fsc_froot)*cc%bliving*cc%Pr + &
               (1-agf_bs)*(1-fsc_wood)*(cc%bwood + cc%bliving*cc%Psw))
     case default
        call error_mesg('vegn_harvest_cropland','The value of soil_carbon_option is invalid. This should never happen. Contact developer.',FATAL)
     end select
     cc%bliving = cc%bliving * (1-fraction_harvested);
     cc%bwood   = cc%bwood   * (1-fraction_harvested);
     ! redistribute leftover biomass between biomass pools
     call update_biomass_pools(cc);
  enddo
end subroutine vegn_harvest_cropland


! ============================================================================
! for now cutting forest is the same as harvesting cropland --
! we basically cut down everything, leaving only seeds
subroutine vegn_cut_forest(vegn, new_landuse)
  type(vegn_tile_type), intent(inout) :: vegn
  integer, intent(in) :: new_landuse ! new land use type that gets assigned to
                                     ! the tile after the wood harvesting

  ! ---- local vars
  type(vegn_cohort_type), pointer :: cc ! pointer to the current cohort
  real :: frac_harvested;        ! fraction of biomass harvested this time
  real :: frac_wood_wasted       ! fraction of wood wasted during transition
  real :: wood_harvested         ! anount of harvested wood, kgC/m2
  real :: bdead, balive, bleaf, bfroot, btotal; ! combined biomass pools
  real :: delta
  integer :: i

  balive = 0 ; bdead = 0 ; bleaf = 0 ; bfroot = 0 ;
  ! calculate initial combined biomass pools for the patch
  do i = 1, vegn%n_cohorts
     cc=>vegn%cohorts(i)
     ! calculate total biomass pools for the patch
     balive = balive + cc%bl + cc%blv + cc%br
     bleaf  = bleaf  + cc%bl + cc%blv
     bfroot = bfroot + cc%br
     bdead  = bdead  + cc%bwood + cc%bsw
  enddo
  btotal = balive+bdead;

  ! calculate harvested fraction: cut everything down to seed level
  if(btotal > 0.0) then
    frac_harvested = MIN(MAX((btotal-crop_seed_density)/btotal,0.0),1.0);
  else
    frac_harvested = 0.0
  endif

  ! define fraction of wood wasted, based on the transition type
  if (new_landuse==LU_SCND) then
     frac_wood_wasted = frac_wood_wasted_harv
  else
     frac_wood_wasted = frac_wood_wasted_clear
  endif
  ! take into accont that all wood below ground is wasted; also the fraction
  ! of waste calculated above is lost from the above-ground part of the wood
  if (waste_below_ground_wood) then
     frac_wood_wasted = (1-agf_bs) + agf_bs*frac_wood_wasted
  endif

  ! update biomass pools for each cohort according to harvested fraction
  do i = 1, vegn%n_cohorts
     cc => vegn%cohorts(i)

     ! calculate total amount of harvested wood, minus the wasted part
     wood_harvested = (cc%bwood+cc%bsw)*frac_harvested*(1-frac_wood_wasted)

     ! distribute harvested wood between pools
     if (new_landuse==LU_SCND) then
        ! this is harvesting, distribute between 3 different wood pools
        vegn%harv_pool(HARV_POOL_WOOD_FAST) = vegn%harv_pool(HARV_POOL_WOOD_FAST) &
             + wood_harvested*frac_wood_fast
        vegn%harv_pool(HARV_POOL_WOOD_MED) = vegn%harv_pool(HARV_POOL_WOOD_MED) &
             + wood_harvested*frac_wood_med
        vegn%harv_pool(HARV_POOL_WOOD_SLOW) = vegn%harv_pool(HARV_POOL_WOOD_SLOW) &
             + wood_harvested*frac_wood_slow
     else
        ! this is land clearance: everything goes into "cleared" pool
        vegn%harv_pool(HARV_POOL_CLEARED) = vegn%harv_pool(HARV_POOL_CLEARED) &
             + wood_harvested
     endif

     ! distribute wood and living biomass between fast and slow intermediate
     ! soil carbon pools according to fractions specified thorough the namelists
     delta = (cc%bwood+cc%bsw)*frac_harvested*frac_wood_wasted;
     if(delta<0) call error_mesg('vegn_cut_forest', &
          'harvested amount of dead biomass ('//string(delta)//' kgC/m2) is below zero', &
          FATAL)

     select case (soil_carbon_option)
     case (SOILC_CENTURY,SOILC_CENTURY_BY_LAYER)
        vegn%ssc_pool_bg = vegn%ssc_pool_bg + delta*(1-fsc_wood)
        vegn%fsc_pool_bg = vegn%fsc_pool_bg + delta*   fsc_wood

        delta = balive * frac_harvested;
        if(delta<0) call error_mesg('vegn_cut_forest', &
             'harvested amount of live biomass ('//string(delta)//' kgC/m2) is below zero', &
             FATAL)
        vegn%ssc_pool_bg = vegn%ssc_pool_bg + delta*(1-fsc_liv) ;
        vegn%fsc_pool_bg = vegn%fsc_pool_bg + delta*   fsc_liv  ;
     case (SOILC_CORPSE)
        vegn%ssc_pool_ag = vegn%ssc_pool_ag + delta*(1-fsc_wood)*agf_bs
        vegn%fsc_pool_ag = vegn%fsc_pool_ag + delta*   fsc_wood*agf_bs
        vegn%ssc_pool_bg = vegn%ssc_pool_bg + delta*(1-fsc_wood)*(1-agf_bs)
        vegn%fsc_pool_bg = vegn%fsc_pool_bg + delta*   fsc_wood*(1-agf_bs)

        vegn%coarsewoodlitter_buffer_ag=vegn%coarsewoodlitter_buffer_ag+delta*agf_bs

        delta = (cc%bl+cc%blv) * frac_harvested;
        if(delta<0) call error_mesg('vegn_cut_forest', &
             'harvested amount of live biomass ('//string(delta)//' kgC/m2) is below zero', &
             FATAL)

        vegn%ssc_pool_ag = vegn%ssc_pool_ag + delta*(1-fsc_liv)  ;
        vegn%fsc_pool_ag = vegn%fsc_pool_ag + delta*   fsc_liv    ;

        vegn%leaflitter_buffer_ag=vegn%leaflitter_buffer_ag+delta

        vegn%ssc_pool_bg = vegn%ssc_pool_bg + bfroot*frac_harvested*(1-fsc_froot)
        vegn%fsc_pool_bg = vegn%fsc_pool_bg + bfroot*frac_harvested*fsc_froot
     case default
        call error_mesg('vegn_phenology','The value of soil_carbon_option is invalid. This should never happen. Contact developer.',FATAL)
     end select

     cc%bliving = cc%bliving*(1-frac_harvested);
     cc%bwood   = cc%bwood*(1-frac_harvested);
     ! redistribute leftover biomass between biomass pools
     call update_biomass_pools(cc);
  enddo
end subroutine vegn_cut_forest

end module
