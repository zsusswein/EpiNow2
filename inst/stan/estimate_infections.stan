functions {
#include functions/pmfs.stan
#include functions/convolve.stan
#include functions/gaussian_process.stan
#include functions/rt.stan
#include functions/infections.stan
#include functions/observation_model.stan
#include functions/generated_quantities.stan
}


data {
#include data/observations.stan
#include data/delays.stan
#include data/gaussian_process.stan
#include data/generation_time.stan
#include data/rt.stan
#include data/backcalc.stan
#include data/observation_model.stan
}

transformed data{
  // observations
  int ot = t - seeding_time - horizon;  // observed time
  int ot_h = ot + horizon;  // observed time + forecast horizon
  // gaussian process
  int noise_terms = setup_noise(ot_h, t, horizon, estimate_r, stationary, future_fixed, fixed_from);
  matrix[noise_terms, M] PHI = setup_gp(M, L, noise_terms);  // basis function
  // Rt
  real r_logmean = log(r_mean^2 / sqrt(r_sd^2 + r_mean^2));
  real r_logsd = sqrt(log(1 + (r_sd^2 / r_mean^2)));

  int delay_max_fixed = (n_fixed_delays == 0 ? 0 :
    sum(delay_max[fixed_delays]) - num_elements(fixed_delays) + 1);
  int delay_max_total = (delays == 0 ? 0 :
    sum(delay_max) - num_elements(delay_max) + 1);
  vector[gt_fixed[1] ? gt_max[1] : 0] gt_fixed_pmf;
  vector[truncation && trunc_fixed[1] ? trunc_max[1] : 0] trunc_fixed_pmf;
  vector[delay_max_fixed] delays_fixed_pmf;

  if (gt_fixed[1]) {
    gt_fixed_pmf = discretised_pmf(gt_mean_mean[1], gt_sd_mean[1], gt_max[1], gt_dist[1], 1);
  }
  if (truncation && trunc_fixed[1]) {
    trunc_fixed_pmf = discretised_pmf(
      trunc_mean_mean[1], trunc_sd_mean[1], trunc_max[1], trunc_dist[1], 0
    );
  }
  if (n_fixed_delays) {
    delays_fixed_pmf = combine_pmfs(
      to_vector([ 1 ]),
      delay_mean_mean[fixed_delays],
      delay_sd_mean[fixed_delays],
      delay_max[fixed_delays],
      delay_dist[fixed_delays],
      delay_max_fixed,
      0
    );
  }
}

parameters{
  // gaussian process
  real<lower = ls_min,upper=ls_max> rho[fixed ? 0 : 1];  // length scale of noise GP
  real<lower = 0> alpha[fixed ? 0 : 1];    // scale of of noise GP
  vector[fixed ? 0 : M] eta;               // unconstrained noise
  // Rt
  vector[estimate_r] log_R;                // baseline reproduction number estimate (log)
  real initial_infections[estimate_r] ;    // seed infections
  real initial_growth[estimate_r && seeding_time > 1 ? 1 : 0]; // seed growth rate
  real<lower = 0, upper = gt_max[1]> gt_mean[estimate_r && gt_mean_sd[1] > 0]; // mean of generation time (if uncertain)
  real<lower = 0> gt_sd[estimate_r && gt_sd_sd[1] > 0];       // sd of generation time (if uncertain)
  real<lower = 0> bp_sd[bp_n > 0 ? 1 : 0]; // standard deviation of breakpoint effect
  real bp_effects[bp_n];                   // Rt breakpoint effects
  // observation model
  real delay_mean[n_uncertain_mean_delays];         // mean of delays
  real<lower = 0> delay_sd[n_uncertain_sd_delays];  // sd of delays
  simplex[week_effect] day_of_week_simplex;// day of week reporting effect
  real<lower = 0, upper = 1> frac_obs[obs_scale];     // fraction of cases that are ultimately observed
  real trunc_mean[truncation && !trunc_fixed[1]];        // mean of truncation
  real<lower = 0> trunc_sd[truncation && !trunc_fixed[1]]; // sd of truncation
  real<lower = 0> rep_phi[model_type];     // overdispersion of the reporting process
}

transformed parameters {
  vector[fixed ? 0 : noise_terms] noise;                    // noise  generated by the gaussian process
  vector<lower = 0, upper = 10 * r_mean>[estimate_r > 0 ? ot_h : 0] R; // reproduction number
  vector[t] infections;                                     // latent infections
  vector[ot_h] reports;                                     // estimated reported cases
  vector[ot] obs_reports;                                   // observed estimated reported cases
  // GP in noise - spectral densities
  if (!fixed) {
    noise = update_gp(PHI, M, L, alpha[1], rho[1], eta, gp_type);
  }
  // Estimate latent infections
  if (estimate_r) {
    // via Rt
    vector[gt_max[1]] gt_pmf;
    gt_pmf = combine_pmfs(
      gt_fixed_pmf, gt_mean, gt_sd, gt_max, gt_dist, gt_max[1], 1, 1
    );
    R = update_Rt(
      ot_h, log_R[estimate_r], noise, breakpoints, bp_effects, stationary
    );
    infections = generate_infections(
      R, seeding_time, gt_pmf, initial_infections, initial_growth, pop,
      future_time
    );
  } else {
    // via deconvolution
    infections = deconvolve_infections(
      shifted_cases, noise, fixed, backcalc_prior
    );
  }
  // convolve from latent infections to mean of observations
  {
    vector[delay_max_total] delay_pmf;
    delay_pmf = combine_pmfs(
      delays_fixed_pmf, delay_mean, delay_sd, delay_max, delay_dist, delay_max_total, 0, 1
    );
    reports = convolve_to_report(infections, delay_pmf, seeding_time);
  }
 // weekly reporting effect
 if (week_effect > 1) {
   reports = day_of_week_effect(reports, day_of_week, day_of_week_simplex);
  }
  // scaling of reported cases by fraction observed
 if (obs_scale) {
   reports = scale_obs(reports, frac_obs[1]);
 }
 // truncate near time cases to observed reports
 if (truncation) {
   vector[trunc_max[1]] trunc_cmf;
   trunc_cmf = reverse_mf(cumulative_sum(combine_pmfs(
     trunc_fixed_pmf, trunc_mean, trunc_sd, trunc_max, trunc_dist, trunc_max[1], 0, 0
   )));
   obs_reports = truncate(reports[1:ot], trunc_cmf, 0);
 } else {
   obs_reports = reports[1:ot];
 }
}

model {
  // priors for noise GP
  if (!fixed) {
    gaussian_process_lp(
      rho[1], alpha[1], eta, ls_meanlog, ls_sdlog, ls_min, ls_max, alpha_sd
    );
  }
  // penalised priors for delay distributions
  delays_lp(
    delay_mean, delay_mean_mean[uncertain_mean_delays],
    delay_mean_sd[uncertain_mean_delays],
    delay_sd, delay_sd_mean[uncertain_sd_delays],
    delay_sd_sd[uncertain_sd_delays], t
  );
  // priors for truncation
  truncation_lp(
    trunc_mean, trunc_sd,
    trunc_mean_mean, trunc_mean_sd,
    trunc_sd_mean, trunc_sd_sd
  );
  if (estimate_r) {
    // priors on Rt
    rt_lp(
      log_R, initial_infections, initial_growth, bp_effects, bp_sd, bp_n,
      seeding_time, r_logmean, r_logsd, prior_infections, prior_growth
    );
    // penalised_prior on generation interval
    generation_time_lp(
      gt_mean, gt_mean_mean, gt_mean_sd, gt_sd, gt_sd_mean, gt_sd_sd, gt_weight
    );
  }
  // prior observation scaling
  if (obs_scale) {
    frac_obs[1] ~ normal(obs_scale_mean, obs_scale_sd) T[0, 1];
  }
  // observed reports from mean of reports (update likelihood)
  if (likelihood) {
    report_lp(
      cases, obs_reports, rep_phi, phi_mean, phi_sd, model_type, obs_weight
    );
  }
}

generated quantities {
  int imputed_reports[ot_h];
  vector[estimate_r > 0 ? 0: ot_h] gen_R;
  real r[ot_h];
  vector[return_likelihood ? ot : 0] log_lik;
  if (estimate_r){
    // estimate growth from estimated Rt
    real set_gt_mean = (gt_mean_sd[1] > 0 ? gt_mean[1] : gt_mean_mean[1]);
    real set_gt_sd = (gt_sd_sd [1]> 0 ? gt_sd[1] : gt_sd_mean[1]);
    r = R_to_growth(R, set_gt_mean, set_gt_sd);
  } else {
    // sample generation time
    real gt_mean_sample[1];
    real gt_sd_sample[1];
    vector[gt_max[1]] gt_pmf;

    gt_mean_sample[1] = (gt_mean_sd[1] > 0 ? normal_rng(gt_mean_mean[1], gt_mean_sd[1]) : gt_mean_mean[1]);
    gt_sd_sample[1] = (gt_sd_sd[1] > 0 ? normal_rng(gt_sd_mean[1], gt_sd_sd[1]) : gt_sd_mean[1]);
    gt_pmf = combine_pmfs(
      gt_fixed_pmf, gt_mean_sample, gt_sd_sample, gt_max, gt_dist, gt_max[1],
      1, 1
    );

    // calculate Rt using infections and generation time
    gen_R = calculate_Rt(
      infections, seeding_time, gt_pmf, rt_half_window
    );
    // estimate growth from calculated Rt
    r = R_to_growth(gen_R, gt_mean_sample[1], gt_sd_sample[1]);
  }
  // simulate reported cases
  imputed_reports = report_rng(reports, rep_phi, model_type);
  // log likelihood of model
  if (return_likelihood) {
    log_lik = report_log_lik(
      cases, obs_reports, rep_phi, model_type, obs_weight
    );
  }
}
