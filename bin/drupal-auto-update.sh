#!/bin/bash

MULTIDEV="update-drupal"

UPDATES_APPLIED=false

# login to Terminus
echo -e "\nLogging into Terminus..."
terminus auth login --machine-token=${TERMINUS_MACHINE_TOKEN}

# delete the multidev environment
echo -e "\nDeleting the ${MULTIDEV} multidev environment..."
terminus site delete-env --remove-branch --yes

# recreate the multidev environment
echo -e "\nRe-creating the ${MULTIDEV} multidev environment..."
terminus site create-env --from-env=live --to-env=${MULTIDEV}

# making sure the multidev is in git mode
echo -e "\nSetting the ${MULTIDEV} multidev to git mode"
terminus site set-connection-mode --mode=git

# check for upstream updates
echo -e "\nChecking for upstream updates on the ${MULTIDEV} multidev..."
# the output goes to stderr, not stdout
UPSTREAM_UPDATES=$(terminus site upstream-updates list  --format=bash  2>&1)

if [[ ${UPSTREAM_UPDATES} == *"No updates"* ]]
then
    # no upstream updates available
    echo -e "\nNo upstream updates found on the ${MULTIDEV} multidev..."
else
    # apply Drupal upstream updates
    echo -e "\nApplying upstream updates on the ${MULTIDEV} multidev..."
    terminus site upstream-updates apply --yes --updatedb --accept-upstream
    UPDATES_APPLIED=true
fi

# making sure the multidev is in SFTP mode
echo -e "\nSetting the ${MULTIDEV} multidev to SFTP mode"
terminus site set-connection-mode --mode=sftp

# check for Drupal plugin updates
echo -e "\nChecking for Drupal plugin updates on the ${MULTIDEV} multidev..."
PLUGIN_UPDATES=$(terminus drush "plugin list --field=update" --format=bash)

if [[ ${PLUGIN_UPDATES} == *"available"* ]]
then
    # update Drupal plugins
    echo -e "\nUpdating Drupal plugins on the ${MULTIDEV} multidev..."
    terminus drush "pm-update --no-core"

    # committing updated Drupal plugins
    echo -e "\nCommitting Drupal plugin updates on the ${MULTIDEV} multidev..."
    terminus site code commit --message="Updated Drupal plugins" --yes
    UPDATES_APPLIED=true
else
    # no Drupal plugin updates found
    echo -e "\nNo Drupal plugin updates found on the ${MULTIDEV} multidev..."
fi

if [[ "${UPDATES_APPLIED}" = false ]]
then
    # no updates applied
    echo -e "\nNo updates to apply..."
    SLACK_MESSAGE="No updates on build #${CIRCLE_BUILD_NUM} for ${CIRCLE_PROJECT_USERNAME}. I'm going back to sleep"
    echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
    curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
else
    # updates applied, carry on

    # install node dependencies
    echo -e "\nRunning npm install..."
    npm install

    # ping the multidev environment to wake it from sleep
    echo -e "\nPinging the ${MULTIDEV} multidev environment to wake it from sleep..."
    curl -I http://update-drupal-florida-conference.pantheonsite.io

    # backstop visual regression
    echo -e "\nRunning BackstopJS tests..."

    cd node_modules/backstopjs

    npm run reference
    # npm run test

    VISUAL_REGRESSION_RESULTS=$(npm run test)

    echo "${VISUAL_REGRESSION_RESULTS}"

    cd -
    if [[ ${VISUAL_REGRESSION_RESULTS} == *"Mismatch errors found"* ]]
    then
        # visual regression failed
        echo -e "\nVisual regression tests failed! Please manually check the ${MULTIDEV} multidev..."
        SLACK_MESSAGE="scalewp.io Circle CI update check #${CIRCLE_BUILD_NUM} by ${CIRCLE_PROJECT_USERNAME}. Visual regression tests failed on <https://dashboard.pantheon.io/sites/${SITE_UUID}#${MULTIDEV}/code|the ${MULTIDEV} environment>! Please test manually."
        echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
        curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
        exit 1
    else
        # visual regression passed
        echo -e "\nVisual regression tests passed between the ${MULTIDEV} multidev and live."

        # enable git mode on dev
        echo -e "\nEnabling git mode on the dev environment..."
        terminus site set-connection-mode --env=dev --mode=git --yes

        # merge the multidev back to dev
        echo -e "\nMerging the ${MULTIDEV} multidev back into the dev environment (master)..."
        terminus site merge-to-dev

        # deploy to test
        echo -e "\nDeploying the updates from dev to test..."
        terminus site deploy --env=test --sync-content --cc --note="Auto deploy of Drupal updates (core, plugin, themes)"

        # backup the live site
        echo -e "\nBacking up the live environment..."
        terminus site backups create --env=live --element=all

        # deploy to live
        echo -e "\nDeploying the updates from test to live..."
        terminus site deploy --env=live --cc --note="Auto deploy of Drupal updates (core, plugin, themes)"

        echo -e "\nVisual regression tests passed! Drupal updates deployed to live..."
        SLACK_MESSAGE="scalewp.io Circle CI update check #${CIRCLE_BUILD_NUM} by ${CIRCLE_PROJECT_USERNAME} Visual regression tests passed! Drupal updates deployed to <https://dashboard.pantheon.io/sites/${SITE_UUID}#live/deploys|the live environment>."
        echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
        curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
    fi
fi
