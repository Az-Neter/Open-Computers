local robot = require("robot")
repeat
robot.up()
robot.forward()
robot.up()
robot.forward()
robot.turnRight()

for i = 1,7 do
  robot.forward()
end

robot.turnRight()

for i = 1,11 do
  robot.forward()
end

robot.turnRight()

for i = 1,35 do
  robot.forward()
end

robot.turnRight()

for i = 1,12 do
  robot.forward()
end

robot.turnRight()

for i = 1,28 do
  robot.forward()
end

robot.turnRight()
robot.down()
robot.forward()
robot.down()
robot.forward()
robot.forward()

robot.turnLeft()
robot.turnLeft()

 until cmd == 'stop'