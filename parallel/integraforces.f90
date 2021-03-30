module integraforces
      use parameters
      use pbc
      contains

      subroutine compute_force_LJ(r,f,U,P)
      !Author: Arnau Jurado
      ! Computes the force, potential energy and pressure of a system
      ! of N particles. Needs the external parameters M,D,L,rc to work
            implicit none
            include 'mpif.h'
            real*8,intent(in)  :: r(D,N)
            real*8,intent(out) :: f(D,N),U,P
            real*8             :: flocal(D,N),Ulocal,Plocal
            real*8             :: distv(D),dist
            real*8             :: rlocal(D,N),coord(N)
            integer            :: i,j
            integer            :: ierror,request

            !Initialize quantities.
            f = 0.d0
            U = 0.d0
            P = 0.d0

            flocal = 0.d0
            Ulocal = 0.d0
            Plocal = 0.d0
            rlocal = r

            do i=1,D
               coord = rlocal(i,:)
               call MPI_BCAST(coord,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request,ierror)
               rlocal(i,:) = coord
            end do


            do i=imin,imax !Loop over assigned particles
                  do j=1,N !We do the full double loop
                     if(i /= j) then
                        !Compute distance and apply minimum image convention.
                        distv = rlocal(:,i)-rlocal(:,j)
                        call min_img(distv)
                        dist = sqrt(sum((distv)**2))


                        if(dist<rc) then !Cutoff
                              !Compute forces and pressure.
                              flocal(:,i) = flocal(:,i)& 
                              + (48.d0/dist**14 - 24.d0/dist**8)*distv

                              Ulocal = Ulocal + 4.d0*((1.d0/dist)**12-(1.d0/dist)**6)-&
                                      4.d0*((1.d0/rc)**12-(1.d0/rc)**6)
                        end if
                     end if
                  end do
                  Plocal = Plocal + sum(rlocal(:,i) * flocal(:,i))
            end do
            call MPI_BARRIER(MPI_COMM_WORLD,ierror)

            do i=1,D
               coord = flocal(i,:)
               call MPI_REDUCE(coord,f(i,:),N,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)
            end do

            call MPI_REDUCE(Ulocal,U,1,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)
            call MPI_REDUCE(Plocal,P,1,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)

            if(taskid==master) then
               !Remove double counting on pot energy
               U = U/2.d0
               !Add 1/3V factor to potential pressure.
               P = 1.d0/(3.d0*L**3)*P
            end if
      end subroutine compute_force_LJ

      subroutine andersen_therm(v,Temp)
         !Author: Arnau Jurado
         !     Applies the Andersen thermostat to a system of N particles. Requires
         !     boxmuller subroutine.
         !           Input
         !           -----
         !                 v : real*8,dimension(D,N)
         !                       Velocities of the system.
         !                 T : real*8
         !                       Target temperature of the thermostat.
         !           Output
         !           ------
         !                 v : real*8,dimension(D,N)
         !                       Velocities of the system after the thermostat application.
            implicit none
            include 'mpif.h'
            real*8,intent(inout) :: v(D,N)
            real*8,intent(in) :: Temp
            real*8 :: std,nu,x1,x2,PI,v_tmp(N),v_local(D,N)
            integer :: im,i,j,request, ierror

            std = sqrt(Temp) !Standard deviation of the gaussian.
            nu = 0.1 ! probability of collision
            PI = 4d0*datan(1d0)

            do i=1,D
               v_tmp = v(i,:)
               call MPI_BCAST(v_tmp,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request,ierror)
               v_local(i,:) = v_tmp
            end do

            do i=imin,imax
               if (rand()<nu) then ! Check if collision happens.
                  do j=1,D
                     x1 = rand()
                     x2 = rand()
                     v_local(j,i) = std*dsqrt(-2d0*dlog(1.d0-x1))*dcos(2d0*PI*x2)
                  enddo
               endif
            enddo

            do i = 1, D
               call MPI_Gatherv(v_local(i,imin:imax), local_size, MPI_DOUBLE_PRECISION, v(i,:), &
                               aux_size, aux_pos, MPI_DOUBLE_PRECISION, master, &
                               MPI_COMM_WORLD, request, ierror)
            end do
                       
            
      end subroutine andersen_therm
                  


     subroutine energy_kin(v,ekin,Tins)
     !Author: Laia Barjuan
     ! Computes the kinetic energy and instant temperature of the
     ! system
        ! --------------------------------------------------
        !  input: 
        !          v  --> velocities of the system
        !  output: 
        !          ekin --> kinetic energy of the system 
        !          Tins --> instant temperature of the system
        ! --------------------------------------------------
      implicit none
      include 'mpif.h'
        real(8), intent(in)   :: v(D,N)
        real(8) :: vlocal(D,N), vec(N), ekinlocal
        real(8), intent (out) :: ekin, Tins
        integer :: i
        integer :: request, ierror

        !Initialization
        ekin=0.0d0
        ekinlocal=0.d0

        do i=1,D
           if (taskid==master) vec = v(i,:)
           call MPI_BCAST(vec,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request,ierror)
           vlocal(i,:) = vec
        end do

        do i=imin,imax
           ekinlocal=ekinlocal+sum(vlocal(:,i)**2)/2.0d0  
        enddo

        call MPI_BARRIER(MPI_COMM_WORLD,ierror)
        call MPI_REDUCE(ekinlocal,ekin,1,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)
     
        !Store instant temperature information in master
        if (taskid==master) Tins=2.0d0*ekin/(3.0d0*N)

        return 
     end subroutine energy_kin



      subroutine verlet_v_step(r,v,fold,t,time_i,dt,U,P)
      !Author: Laia Barjuan
      ! Computes one time step with velocity verlet algorithm 
         ! --------------------------------------------------
         ! input: 
         !        r --> positions of the particles
         !        v  --> velocities of the system
         !        fold --> force at t
         !        time_i --> number of step
         !        dt --> time step
         ! output: 
         !         modified r and v
         !         t --> final time
         !         U --> potential energy 
         !         P --> potential pressure
         ! --------------------------------------------------
         implicit none 
         include 'mpif.h'
         integer :: i, time_i
         real(8) :: r(D,N), v(D,N), U, f(D,N), fold(D,N), t, dt, P
         real(8) :: flocal(D,N), vlocal(D,N), rlocal(D,N), flocal_old(D,N)
         real(8) :: vec1(N), vec2(N), vec3(N)
         integer :: request, request1, request2, request3, ierror, ierror1, ierror2, ierror3

         !Initialize variables
         rlocal=0.d0
         vlocal=0.0d0
         flocal=0.0d0
         flocal_old=0.0d0

         !Get information from master
         do i=1,D
            if (taskid==master) then
               vec1 = fold(i,:)
               vec2 = v(i,:)
               vec3 = r(i,:)
            endif
            call MPI_BCAST(vec1,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request1,ierror1)
            call MPI_BCAST(vec2,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request2,ierror2)
            call MPI_BCAST(vec3,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request3,ierror3)
            flocal_old(i,imin:imax) = vec1(imin:imax)
            vlocal(i,imin:imax) = vec2(imin:imax)
            rlocal(i,imin:imax) = vec3(imin:imax)
         end do

         !Change of positions and velocities
         do i=imin,imax
            rlocal(:,i)=rlocal(:,i)+vlocal(:,i)*dt +flocal_old(:,i)*dt**2*0.5d0
            call min_img(rlocal(:,i))  !Apply PBC
         enddo


         !Save new positions information in master
         do i=1,D
            vec3 = rlocal(i,:)
            call MPI_REDUCE(vec3,r(i,:),N,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror3)
         end do

         !forces at t+dt
         call compute_force_LJ(r,f,U,P)

         !Get forces information from master
         do i=1,D
            if (taskid==master) vec1 = f(i,:)
            call MPI_BCAST(vec1,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request1,ierror1)
            flocal(i,imin:imax) = vec1(imin:imax)
         end do
         
         do i=imin,imax
            vlocal(:,i)=vlocal(:,i)+(flocal_old(:,i)+flocal(:,i))*dt*0.5d0
         enddo 

         !Save new velocities information in master
         do i=1,D
            vec2 = vlocal(i,:)
            call MPI_REDUCE(vec2,v(i,:),N,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror2)
         end do

         if (taskid==master) then
            fold=f
            t=time_i*dt !Update time
         endif 
         return
      end subroutine verlet_v_step


      subroutine vvel_solver(Nt,dt,r,v,Temp,eunit,eunit_g,flag_g)
      !Author: Laia Barjuan
      !Co-Authors: David March (radial distribution), Arnau Jurado (interface
      !with forces)
!     Performs Nt steps of the velocity verlet algorithm while computing
!     different observables and writing to file.
         ! --------------------------------------------------
         ! input: 
         !        Nt --> number of time steps
         !        dt  --> time step
         !        r --> positions of the particles
         !        v  --> velocities of the system
         !        T --> temperature of the system
         !        eunit --> unit of file to write energies and temperature
         !        eunit_g --> unit of file to write g(r)
         !        flag_g --> different to a non-zero int to write files
         ! output: 
         !         modified r and v
         ! --------------------------------------------------
         !use rad_dist
         implicit none
         include 'mpif.h'
         integer, intent(in) :: Nt, eunit, eunit_g
         real(8) :: dt, Temp
         real(8) :: r(D,N), v(D,N), f(D,N), fold(D,N)
         real(8) :: ekin, U, t, Tins, Ppot, Ptot
         integer :: i,j
         ! Flags for writing g:
         integer, intent(in) :: flag_g
         integer :: Nshells
         
         ! Initialization of the g(r) calculation:
         !if(flag_g.ne.0) then
         !  Nshells = 100
         !  call prepare_shells_and_procs(Nshells,numproc) !LB: numproc not necessary (already in param)
         !endif

         t = 0.d0
         call compute_force_LJ(r,f,U,Ppot) !Initial force, energy and pressure
         call energy_kin(v,ekin,Tins) !Compute initial kinetic energy
         if (taskid==master) Ptot = rho*Tins + Ppot !AJ: modifed to use the rho in parameters.

         !Write intial results.
         if (taskid==master) then
             write(eunit,*)"#t,   K,   U,  E,  T,  v_tot,  Ptot"
             write(eunit,*) t, ekin, U, ekin+U, Tins, dsqrt(sum(sum(v,2)**2)), Ptot
         endif
             
         if (taskid==master) fold=f
         do i=1,Nt !Main time loop.
            call verlet_v_step(r,v,fold,t,i,dt,U,Ppot) !Perform Verlet step.
            call andersen_therm(v,Temp) !Apply thermostat
            call energy_kin(v,ekin,Tins)
            if (taskid==master) Ptot = rho*Tins + Ppot

            !Write to file.
            if (taskid==master) write(eunit,*) t, ekin, U, ekin+U, Tins, dsqrt(sum(sum(v,2)**2)), Ptot
            
            !Write snapshot of g(r)
            !if(flag_g.ne.0) then
            !  call rad_distr_fun(r,Nshells)
            !  do j=1,Nshells
            !      write(eunit_g,*) (j-1)*grid_shells, g(j)
            !  enddo
            !  write(eunit_g,*) ! separation line
            !endif
            
         enddo

         return
      end subroutine vvel_solver


end module integraforces
