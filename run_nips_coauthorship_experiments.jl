@everywhere require("mcmc.jl")
@everywhere require("data_utils.jl")
@everywhere require("read_nips_data.jl")
@everywhere require("experiment_utils.jl")

symmetric = true
model_spec = ModelSpecification(false, false, false, symmetric, false, ones(3)/3, 0.2, 1.0, false, false)

X_r = zeros((0,0,0))
X_p = zeros((0,0))
X_c = zeros((0,0))

trnpct = 0.8
run_batch(model_spec, YY, trnpct, 0.3, 0.5, 500, 200, 10, "NIPS_test_$trnpct", "../results")

# split into train/test
#Ytrain, Ytest = train_test_split(YY, .8)
#
#
#data = DataState(Ytrain, Ytest, X_r, X_p, X_c)
#
#results = mcmc(data, 0.01, 0.5, model_spec, 5)
#models = results[end]
#model = models[end]
## can't save models directly
#save("testfile.jlz", results[1:end-1])
#save("testmodel.jlz", model2array(model)
