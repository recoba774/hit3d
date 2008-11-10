subroutine init_scalars

  use m_openmpi
  use m_parameters
  use m_io
  use m_fields
  use m_work
  use x_fftw
  use m_rand_knuth
  use RANDu

  implicit none

  integer :: i, j, k, n, n_scalar
  integer *8 :: i8

  real*8, allocatable :: e_spec(:), e_spec1(:), rr(:)
  integer *8, allocatable :: hits(:), hits1(:)

  integer   :: n_shell
  real*8    :: sc_rad1, sc_rad2

  real*8 :: wmag, wmag2, ratio, fac


!================================================================================
  allocate( e_spec(kmax), e_spec1(kmax), hits(kmax), hits1(kmax), rr(nx+2), stat=ierr)

  write(out,*) 'Generating random scalars'
  call flush(out)

  ! Initializing the random sequence with the seed RN2
  fac = random(-RN2)

  main_cycye: do n_scalar = 1,n_scalars

     write(out,*) " Generating scalar # ",n_scalar
     call flush(out)


     ! bringing the processors to their own places in the random sequence
     ! ("2" is there because we're generating two random number fields
     ! for each scalar field

     ! using i8 because it's int*8
     do i8 = 1,myid*(nx+2)*ny*nz*2
        fac = random(RN2)
     end do

     ! now filling the arrays wrk1, wrk2
     do n = 1,2
        do k = 1,nz
           do j = 1,ny
              do i = 1,nx+2
                 wrk(i,j,k,n) = random(RN2)
              end do
           end do
        end do
     end do

     ! bringing the random numbers to the same 
     ! point in the sequence again
     do i8 = 1,(numprocs-myid-1)*(nx+2)*ny*nz*2
        fac = random(RN2)
     end do

     ! making  random array with Gaussian PDF 
     ! out of the two arrays that we generated
     wrk(:,:,:,3) = sqrt(-two*log(wrk(:,:,:,1))) * sin(TWO_PI*wrk(:,:,:,2))

     ! go to Fourier space
     call xFFT3d(1,3)

!-------------------------------------------------------------------------------
!     Calculating the scalar spectrum
!-------------------------------------------------------------------------------

     ! need this normalization factor because the FFT is unnormalized
     fac = one / real(nx*ny*nz_all)**2

     e_spec1 = zip
     e_spec = zip
     hits = 0
     hits1 = 0

     ! assembling the scalar energy in each shell and number of hits in each shell
     do k = 1,nz
        do j = 1,ny
           do i = 1,nx

              n_shell = nint(sqrt(real(akx(i)**2 + aky(k)**2 + akz(j)**2, 4)))
              if (n_shell .gt. 0 .and. n_shell .le. kmax) then
                 hits1(n_shell) = hits1(n_shell) + 1
                 e_spec1(n_shell) = e_spec1(n_shell) + fac * wrk(i,j,k,3)**2
              end if
           end do
        end do
     end do

     ! reducing the number of hits and energy to two arrays on master node
     count = kmax
     call MPI_REDUCE(hits1,hits,count,MPI_INTEGER8,MPI_SUM,0,MPI_COMM_TASK,mpi_err)
     call MPI_REDUCE(e_spec1,e_spec,count,MPI_REAL8,MPI_SUM,0,MPI_COMM_TASK,mpi_err)


     ! now the master node counts the energy density in each shell
     if (myid.eq.0) then
        fac = four/three * PI / two
        do k = 1,kmax
           sc_rad1 = real(k,8) + half
           sc_rad2 = real(k,8) - half
           if (k.eq.1) sc_rad2 = 0.d0
           if (hits(k).gt.0) then
              e_spec(k) = e_spec(k) / hits(k) * fac * (sc_rad1**3 - sc_rad2**3)
           else
              e_spec(k) = zip
           end if
        end do
     end if

     ! broadcasting the spectrum
     count = kmax
     call MPI_BCAST(e_spec,count,MPI_REAL8,0,MPI_COMM_TASK,mpi_err)

!-------------------------------------------------------------------------------
!  Now make the spectrum to be as desired
!-------------------------------------------------------------------------------


     ! first, define the desired spectrum
     do k = 1,kmax

        wmag = real(k, 8)
        ratio = wmag / peak_wavenum_sc(n_scalar)

        if (scalar_type(n_scalar).eq.0) then
           ! Plain Kolmogorov spectrum
           e_spec1(k) = wmag**(-5.d0/3.d0)

        else if (scalar_type(n_scalar).eq.1 .or. scalar_type(n_scalar).eq.3) then
           ! Exponential spectrum
           e_spec1(k) =  ratio**3 / peak_wavenum_sc(n_scalar) * exp(-3.0D0*ratio)

        else if (scalar_type(n_scalar).eq.2) then
           ! Von Karman spectrum
           fac = two * PI * ratio
           e_spec1(k) = fac**4 / (one + fac**2)**3

        else
           write(out,*) "INIT_SCALARS: WRONG INITIAL SPECTRUM TYPE: ",scalar_type(n_scalar)
           call flush(out)
           stop

        end if
     end do

     ! normalize it so it has the unit total energy
     e_spec1 = e_spec1 / sum(e_spec1(1:kmax))


     ! now go over all Fourier shells and multiply the velocities in a shell by
     ! the sqrt of ratio of the resired to the current spectrum
     fields(:,:,:,3+n_scalar) = zip



     do k = 1,nz
        do j = 1,ny
           do i = 1,nx+2

              n_shell = nint(sqrt(real(akx(i)**2 + aky(k)**2 + akz(j)**2, 4)))
              if (n_shell .gt. 0 .and. n_shell .le. kmax .and. e_spec(n_shell) .gt. zip) then
                 fields(i,j,k,3+n_scalar) = wrk(i,j,k,3) * sqrt(e_spec1(n_shell)/e_spec(n_shell))
              else
                 fields(i,j,k,3+n_scalar) = zip
              end if

           end do
        end do
     end do

!-------------------------------------------------------------------------------
!   Creating scalars with double-delta PDF
!-------------------------------------------------------------------------------

     if (scalar_type(n_scalar).eq.3) then
        wrk(:,:,:,0) = fields(:,:,:,3+n_scalar)
        call xFFT3d(-1,0)

        ! making it double-delta (0.9 and -0.9)
        wrk(:,:,:,0) = sign(one,wrk(:,:,:,0)) * 0.9d0
        call xFFT3d(1,0)

        ! smoothing it by zeroing out high harmonics
        do k = 1,nz
           do j = 1,ny
              do i = 1,nx+2
                 n_shell = nint(sqrt(real(akx(i)**2 + aky(k)**2 + akz(j)**2, 4)))
                 if (n_shell .eq. 0 .or. n_shell .ge. kmax*2/3) then
                    wrk(i,j,k,0) = zip
                 end if
              end do
           end do
        end do
        fields(:,:,:,3+n_scalar) = wrk(:,:,:,0)


     end if



  end do main_cycye



  ! deallocate work arrays
  deallocate(e_spec, e_spec1, rr, hits, hits1, stat=ierr)

  write(out,*) "Generated the scalars."
  call flush(out)

  return
end subroutine init_scalars
