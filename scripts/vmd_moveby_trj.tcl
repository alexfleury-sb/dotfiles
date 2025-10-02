set sel [atomselect 0 all]

for {set i 0} {$i =< 10002} {incr i} {
    $sel frame $i
    $sel moveby {x y z}
}
