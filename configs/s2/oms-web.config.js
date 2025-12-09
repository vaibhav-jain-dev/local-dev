// OMS-Web Configuration - S2
module.exports = {
  API_HOST: 'http://localhost:8080/api',
  GEOMARK_API_KEY: '5e7LiT7366AmSIi1mxxeYRXo',
  GEOMARK_API_URL: 'https://s2-geomark-api.orangehealth.dev',
  GMAPS_ID: 'orangehealth-dev-maps',
  GOOGLE_MAPS_API_KEY: 'AIzaSyDwC4zKGAWYREzkEBZ5rNhYmUJEWraMpvc',
  LOG_PATH: '/',
  MIXPANEL_PROJECT_TOKEN_LOGISTICS: 'e0414c91421553a948eab60bb1368ea3',
  OH_REPORTS_ENABLE: true,
  OH_WEB_URL_NEW: 'https://s2-partner-order.orangehealth.dev',
  OH_WEB_URL: 'https://s2-web.orangehealth.dev',
  OMS_CITY_CODE_LABELS: {
    BLR: 'Bengaluru',
    DEL: 'Gurugram',
    NRL: 'National Referral',
    MUM: 'Mumbai',
    NOA: 'Noida',
    HYD: 'Hyderabad'
  },
  OMS_CITY_CODES: 'BLR,DEL,HYD,MUM,NOA,NRL',
  OMS_FEEDBACK_URL: 'https://s2-feedback.orangehealth.dev',
  OMS_PARTNER_TOKEN: '9ibRUd64VwXCCAuL84uQ3PmP',
  RTPCR_MASTERTEST_ID: 461,
  SUPERLAB_URL: 'https://s2-superlab.orangehealth.dev',
  SERVER_HOST: 'https://s2-oms.orangehealth.dev',
  SERVER_PORT: 8182,
  SRF_CITY_CONFIGS: {
    BLR: {
      otpRequired: true,
      requiresAddressProof: false,
      travellingCheckBoxLabel: 'Patient is travelling',
      poiIdRequired: false,
      requiresVaccinationData: false
    },
    DEL: {
      otpRequired: false,
      requiresAddressProof: true,
      travellingCheckBoxLabel: 'International traveller',
      poiIdRequired: true,
      requiresVaccinationData: false
    },
    NDM: {
      otpRequired: false,
      requiresAddressProof: true,
      travellingCheckBoxLabel: 'International traveller',
      poiIdRequired: true,
      requiresVaccinationData: false
    },
    NOA: {
      otpRequired: false,
      requiresAddressProof: true,
      travellingCheckBoxLabel: 'International traveller',
      poiIdRequired: true,
      requiresVaccinationData: false
    },
    HYD: {
      otpRequired: false,
      requiresAddressProof: true,
      travellingCheckBoxLabel: 'Patient is travelling',
      poiIdRequired: true,
      requiresVaccinationData: false
    },
    MUM: {
      otpRequired: false,
      requiresAddressProof: false,
      travellingCheckBoxLabel: 'Patient is travelling',
      poiIdRequired: false,
      requiresVaccinationData: false
    },
    MVS: {
      otpRequired: true,
      requiresAddressProof: false,
      travellingCheckBoxLabel: 'Patient is travelling',
      poiIdRequired: false,
      requiresVaccinationData: false
    }
  }
};
