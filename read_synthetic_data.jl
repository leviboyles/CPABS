using MAT

synthetic_data = matopen("jimmy_synthetic/synthetic_1_julia.mat")

Y = read(synthetic_data["Xnew"]);
Z = read(synthetic_data["Znew"]);
W = read(synthetic_data["W"]);

YY = Array(Array{Int64,2},1)
YY[1] = Y
