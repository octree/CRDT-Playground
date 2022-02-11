import Foundation

var setX = ORSet<String, Int>()
let (phone, pad) = (0, 1)
setX.inset("A", replicaID: phone)
setX.inset("B", replicaID: phone)
setX.remove("B", replicaID: phone)
setX.inset("C", replicaID: phone)
print(setX.value, setX.additions, setX.removals)
print("")
var setY = setX
setY.inset("B", replicaID: pad)
setY.remove("C", replicaID: pad)
setY.inset("D", replicaID: pad)
print(setY.value, setY.additions, setY.removals)
print("")

setX.inset("E", replicaID: phone)

let merged = setX.merging(with: setY)
print(merged.value, merged.additions, merged.removals)
