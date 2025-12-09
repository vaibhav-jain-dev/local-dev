#!/bin/bash

# Mask AWS keys
sed -E 's/(AKIA[0-9A-Z]{16})/MASKED_AWS_KEY/g' |

# Mask AWS Secret keys
sed -E 's/([A-Za-z0-9/+=]{40})/MASKED_SECRET/g' |

# Mask Slack tokens (xoxb/xoxa/xoxp)
sed -E 's/(xox[baprs]-[0-9A-Za-z-]+)/MASKED_SLACK_TOKEN/g' |

# Mask JSON private_key fields
sed -E 's/"private_key": ".*"/"private_key": "MASKED_PRIVATE_KEY"/g'

