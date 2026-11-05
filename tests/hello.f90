program hello
    implicit none
    integer, parameter :: n = 1000
    integer :: i
    real(8) :: a(n), s

    do concurrent (i = 1:n)
        a(i) = real(i, 8)
    end do
    s = sum(a)
    print '(a, f0.1)', 'Fortran sum=', s
    if (s /= 500500.0d0) error stop 1
end program hello
