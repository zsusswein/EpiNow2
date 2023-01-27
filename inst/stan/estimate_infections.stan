functions {
#include functions/convolve.stan
#include functions/pmfs.stan
#include functions/delays.stan
#include functions/gaussian_process.stan
#include functions/covariates.stan
#include functions/infections.stan
#include functions/observation_model.stan
#include functions/generated_quantities.stan
}


data {
#include data/observations.stan
#include data/delays.stan
#include data/covariates.stan
#include data/gaussian_process.stan
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
  // covariate mean
  real cov_mean_logmean[cov_mean_const];
  real cov_mean_logsd[cov_mean_const];

  if (cov_mean_const) {
    cov_mean_logmean[1] = log(cov_mean_mean[1]^2 / sqrt(cov_mean_sd[1]^2 + cov_mean_mean[1]^2));
    cov_mean_logsd[1] = sqrt(log(1 + (cov_mean_sd[1]^2 / cov_mean_mean[1]^2)));
  }

  array[delay_types] int delay_type_max;
  profile("assign max") {
    delay_type_max = get_delay_type_max(
      delay_types, delay_types_p, delay_types_id,
      delay_types_groups, delay_max, delay_np_pmf_groups
    );
  }
}

parameters{
  // gaussian process
  array[fixed ? 0 : 1] real<lower = ls_min,upper=ls_max> rho;  // length scale of noise GP
  array[fixed ? 0 : 1] real<lower = 0> alpha;    // scale of of noise GP
  vector[fixed ? 0 : M] eta;               // unconstrained noise
  // Rt
  vector[cov_mean_const] log_cov_mean;           // covariate (R/r)
  array[estimate_r] real initial_infections ;    // seed infections
  array[estimate_r && seeding_time > 1 ? 1 : 0] real initial_growth; // seed growth rate
  array[bp_n > 0 ? 1 : 0] real<lower = 0> bp_sd; // standard deviation of breakpoint effect
  array[bp_n] real bp_effects;                   // Rt breakpoint effects
  // observation model

  vector<lower = delay_params_lower>[delay_params_length] delay_params; // delay parameters
  simplex[week_effect] day_of_week_simplex;// day of week reporting effect
  array[obs_scale_sd > 0 ? 1 : 0] real<lower = 0, upper = 1> frac_obs;     // fraction of cases that are ultimately observed
  array[obs_dist] real<lower = 0> rep_phi;     // overdispersion of the reporting process
}

transformed parameters {
  vector[fixed ? 0 : noise_terms] noise;                    // noise  generated by the gaussian process
  vector[seeding_time] uobs_inf;
  vector[t] infections;                                     // latent infections
  vector[ot_h] cov;                                         // covariates
  vector[ot_h] reports;                                     // estimated reported cases
  vector[ot] obs_reports;                                   // observed estimated reported cases
  vector[estimate_r * (delay_type_max[gt_id] + 1)] gt_rev_pmf;
  // GP in noise - spectral densities
  profile("update gp") {
    if (!fixed) {
      noise = update_gp(PHI, M, L, alpha[1], rho[1], eta, gp_type);
    }
  }
  // update covariates
  cov = update_covariate(
    log_cov_mean, cov_t, noise, breakpoints, bp_effects,
    stationary, ot_h
  );
  uobs_inf = generate_seed(initial_infections, initial_growth, seeding_time);
  // Estimate latent infections
  if (process_model == 0) {
    // via deconvolution
    profile("infections") {
      infections = infection_model(cov, uobs_inf, future_time);
    }
  } else if (process_model == 1) {
    // via growth
    infections = growth_model(cov, uobs_inf, future_time);
  } else if (process_model == 2) {
    // via Rt
    profile("gt") {
      gt_rev_pmf = get_delay_rev_pmf(
        gt_id, delay_type_max[gt_id] + 1, delay_types_p, delay_types_id,
        delay_types_groups, delay_max, delay_np_pmf,
        delay_np_pmf_groups, delay_params, delay_params_groups, delay_dist,
        1, 1, 0
      );
    }
    profile("infections") {
      infections = renewal_model(
        cov, uobs_inf, gt_rev_pmf, pop, future_time
      );
    }
  }
  // convolve from latent infections to mean of observations
  if (delay_id) {
    vector[delay_type_max[delay_id] + 1] delay_rev_pmf;
    profile("delays") {
      delay_rev_pmf = get_delay_rev_pmf(
        delay_id, delay_type_max[delay_id] + 1, delay_types_p, delay_types_id,
        delay_types_groups, delay_max, delay_np_pmf,
        delay_np_pmf_groups, delay_params, delay_params_groups, delay_dist,
        0, 1, 0
      );
    }
    profile("reports") {
      reports = convolve_to_report(infections, delay_rev_pmf, seeding_time);
    }
  } else {
    reports = infections[(seeding_time + 1):t];
  }
  // weekly reporting effect
  if (week_effect > 1) {
    profile("day of the week") {
      reports = day_of_week_effect(reports, day_of_week, day_of_week_simplex);
    }
  }
  // scaling of reported cases by fraction observed
  if (obs_scale) {
    profile("scale") {
      reports = scale_obs(
        reports, obs_scale_sd > 0 ? frac_obs[1] : obs_scale_mean
      );
    }
  }
  // truncate near time cases to observed reports
  if (trunc_id) {
    vector[delay_type_max[trunc_id] + 1] trunc_rev_cmf;
    profile("truncation") {
      trunc_rev_cmf = get_delay_rev_pmf(
        trunc_id, delay_type_max[trunc_id] + 1, delay_types_p, delay_types_id,
        delay_types_groups, delay_max, delay_np_pmf,
        delay_np_pmf_groups, delay_params, delay_params_groups, delay_dist,
        0, 1, 1
      );
    }
    profile("truncate") {
      obs_reports = truncate(reports[1:ot], trunc_rev_cmf, 0);
    }
  } else {
    obs_reports = reports[1:ot];
  }
}

model {
  // priors for noise GP
  if (!fixed) {
    profile("gp lp") {
      gaussian_process_lp(
        rho[1], alpha[1], eta, ls_meanlog, ls_sdlog, ls_min, ls_max, alpha_sd
      );
    }
  }
  // penalised priors for delay distributions
  profile("delays lp") {
    delays_lp(
      delay_params, delay_params_mean, delay_params_sd, delay_params_groups,
      delay_dist, delay_weight
    );
  }
  profile("covariate lp") {
    covariate_lp(
      log_cov_mean, bp_effects, bp_sd, bp_n, cov_mean_logmean, cov_mean_logsd
    );
  }
  profile("infections lp") {
    infections_lp(
      initial_infections, initial_growth, prior_infections, prior_growth,
      seeding_time
    );
  }
  // prior observation scaling
  if (obs_scale_sd > 0) {
    profile("scale lp") {
      frac_obs[1] ~ normal(obs_scale_mean, obs_scale_sd) T[0, 1];
    }
  }
  // observed reports from mean of reports (update likelihood)
  if (likelihood) {
    profile("report lp") {
      report_lp(
        cases, cases_time, obs_reports, rep_phi, phi_mean, phi_sd, obs_dist,
        obs_weight, accumulate
      );
    }
  }
}

generated quantities {
  array[ot_h] int imputed_reports;
  vector[estimate_r > 0 ? 0: ot_h] R;
  vector[ot_h - 1] r;
  vector[return_likelihood ? ot : 0] log_lik;
  profile("generated quantities") {
    if (estimate_r == 0 && process_model != 2) {
      // sample generation time
      vector[delay_params_length] delay_params_sample = to_vector(normal_lb_rng(
        delay_params_mean, delay_params_sd, delay_params_lower
      ));
      vector[delay_type_max[gt_id] + 1] sampled_gt_rev_pmf = get_delay_rev_pmf(
        gt_id, delay_type_max[gt_id] + 1, delay_types_p, delay_types_id,
        delay_types_groups, delay_max, delay_np_pmf,
        delay_np_pmf_groups, delay_params_sample, delay_params_groups,
        delay_dist, 1, 1, 0
      );
      // calculate Rt using infections and generation time
      R = calculate_Rt(infections, seeding_time, sampled_gt_rev_pmf);
    } else {
      R = cov;
    }
    // estimate growth from infections
    if (process_model != 1) {
      r = calculate_growth(infections, seeding_time);
    } else {
      r = cov;
    }
    // simulate reported cases
    imputed_reports = report_rng(reports, rep_phi, obs_dist);
    // log likelihood of model
    if (return_likelihood) {
      log_lik = report_log_lik(
        cases, obs_reports[cases_time], rep_phi, obs_dist, obs_weight
      );
    }
  }
}
