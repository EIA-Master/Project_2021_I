   module integraforces
         use parameters
         use pbc
         contains

         subroutine compute_force_LJ(r,f,U,P)
         ! Computes the force, potential energy and pressure of a system
         ! of N particles. Needs the external parameters M,D,L,rc to work
               implicit none
               real*8,intent(in) :: r(D,N)
               real*8,intent(out) :: f(D,N),U,P
               real*8 :: distv(D),dist
               integer :: i,j
               f = 0.d0
               U = 0.d0
               P = 0.d0
               do i=1,N
                     do j=i+1,N
                           distv = r(:,i)-r(:,j)
                           ! call pbc(distv) !PBC goes here
                           dist = sqrt(sum((distv)**2))
                           if(dist<rc) then
                                 f(:,i) = f(:,j)& 
                                 + (48.d0/dist**14 - 24.d0/dist**8)*distv
                                 f(:,j) = f(:,j)& 
                                 - (48.d0/dist**14 - 24.d0/dist**8)*distv
   
                                 U = U + 4.d0*((1.d0/dist)**12-(1.d0/dist)**6)-&
                                         4.d0*((1.d0/rc)**12-(1.d0/rc)**6)
                                 P = P + sum(distv * f(:,i))
                           endif
                     enddo
               enddo
               ! P = P/(dble(N)*(dble(N)-1.d0)/2.d0)

               P = rho*T_ref + 1.d0/(3.d0*L**3)*P
         end subroutine compute_force_LJ


         subroutine energykin(v,ekin,Tins)
         ! Computes the kinetic energy and instant temperature of the
         ! system
            implicit none
            real(8), intent(in) :: v(D,N)
            real(8), intent (out) :: ekin,Tins
            integer :: i
            
            ekin=0.0d0
            do i=1,N
               ekin=ekin+sum(v(:,i)**2)/2.0d0  
            enddo

            Tins=2.0d0*ekin/(3.0d0*N)
            return 
         end subroutine energykin


         subroutine verlet_v_step(r,v,t,dt)
         ! Computes one time step with velocity verlet algorithm 
            implicit none 
            integer :: i
            real(8) :: r(D,N), v(D,N), U, f(D,N), t, dt, P
            ! --------------------------------------------------
            ! input: r and v
            ! output: modified r and v
            ! --------------------------------------------------

            !forces at t
            call compute_force_LJ(r,f,U,P)

            !change of positions
            do i=1,N
               r(:,i)=r(:,i)+v(:,i)*dt +f(:,i)*dt**2/2.0d0
               !Apply PBC
               call min_img_2(r(:,i)) 

               v(:,i)=v(:,i)+f(:,i)*dt*0.5d0
            enddo

            !forces at t+dt
            call compute_force_LJ(r,f,U,P)

            do i=1,N
               v(:,i)=v(:,i)+f(:,i)*dt*0.5d0
            enddo 

            t=t+dt !Update time
            return
         end subroutine verlet_v_step


         subroutine vvel_solver(Nt,dt,r,v,Temp,eunit) !Nt -- n_total?
   !     Performs Nt steps of the velocity verlet algorithm while computing
   !     different observables and writing to file.
            implicit none
            integer, intent(in) :: Nt, eunit
            real(8) :: dt, Temp
            real(8) :: r(D,N), v(D,N), f(D,N)
            real(8) :: ekin, U, t, Tins, Ppot, Ptot
            integer :: i,j

            t = 0.d0
            call compute_force_LJ(r,f,U,Ppot) !Initial force, energy and pressure
            call energykin(v,ekin,Tins) !Compute initial kinetic energy
            Ptot = (dble(N)/L**3)*Tins + 1.d0/(3.d0*L**3)*Ppot !Total pressure

            !Write intial results.
            write(eunit,*)"t","K","U","E","T","v_tot"
            write(eunit,*) t, ekin, U, ekin+U, Tins, sum(v,2)
            !do i=1,N   !Writes initial configuration of particles
              ! write(runit,*) r(:,i)
            !enddo
      
            do i=1,Nt !Main time loop.
               call verlet_v_step(r,v,t,dt) !Perform Verlet step.
               !call andersen(D,N,v,Temp) !Apply thermostat
               call compute_force_LJ(r,f,U,Ppot)
               call energykin(v,ekin,Tins)
               Ptot = (dble(N)/L**3)*Tins + 1.d0/(3.d0*L**3)*Ppot

               !Write to file.
               write(eunit,*) t, ekin, U, ekin+U, Tins, sum(v,2)
            enddo

            return
         end subroutine vvel_solver


   end module integraforces
