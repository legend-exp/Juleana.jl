using ProgressMeter

x,n = 1,10
p = Progress(n)
for iter = 1:10
    x *= 2
    sleep(0.5)
    ProgressMeter.next!(p; showvalues = [(:iter,iter), (:x,x)])
end