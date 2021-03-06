library(reshape2)
d <- read.csv('fig4/fig4.csv')
z <- as.matrix((dcast(d, price ~ quantity, value.var="utility")))
image(z, col=terrain.colours(20))
contour(z, nlevels=20)
