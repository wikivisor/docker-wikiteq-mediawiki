#!/bin/bash

set -e

# Map the site hostname to 172.17.0.1 for VisualEditor
MW_SITE_HOST=$(echo "$MW_SITE_SERVER" | sed -e 's|^[^/]*//||' -e 's|[:/].*$||')
cp /etc/hosts ~/hosts.new
sed -i '/# MW_SITE_HOST/d' ~/hosts.new

if [ "$MW_MAP_DOMAIN_TO_DOCKER_GATEWAY" != true ]; then
    echo "MW_MAP_DOMAIN_TO_DOCKER_GATEWAY is not true"
elif [[ $MW_SITE_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "MW_SITE_HOST is IP address '$MW_SITE_HOST'"
else
  echo "Add MW_SITE_HOST '172.17.0.1 $MW_SITE_HOST' to /etc/hosts"
  echo "172.17.0.1 $MW_SITE_HOST # MW_SITE_HOST" >> ~/hosts.new
fi
cp -f ~/hosts.new /etc/hosts

# Create needed directories
rsync -avh --ignore-existing "$MW_ORIGIN_FILES"/ "$MW_VOLUME"/
mkdir -p "$MW_VOLUME"/extensions/SemanticMediaWiki/config

# Allow to write to the directories
chgrp -R "$WWW_GROUP" "$MW_VOLUME"
chmod -R g=rwX "$MW_VOLUME"
chgrp -R "$WWW_GROUP" /var/log/httpd
chmod -R g=rwX /var/log/httpd

wait_database_started ()
{
    if [ -n "$db_started" ]; then
        return 0; # already started
    fi

    echo "Waiting for database to start"
    mysql=( mysql -h db -u"$1" -p"$2" )

    for i in {86400..0}; do
        if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
                break
        fi
        echo 'Waiting for database to start...'
        sleep 1
    done
    if [ "$i" = 0 ]; then
        echo >&2 'Could not connect to the database.'
        return 1
    fi
    echo 'Successfully connected to the database.'
    db_started="1"
    return 0
}

wait_elasticsearch_started ()
{
    if [ -n "$es_started" ]; then
        return 0; # already started
    fi

    echo 'Waiting for elasticsearch to start'
    for i in {300..0}; do
        result=0
        output=$(wget --timeout=1 -q -O - http://elasticsearch:9200/_cat/health) || result=$?
        if [[ "$result" = 0 && $(echo "$output"|awk '{ print $4 }') = "green" ]]; then
            break
        fi
        if [ "$result" = 0 ]; then
            echo "Waiting for elasticsearch health status changed from [$(echo "$output"|awk '{ print $4 }')] to [green]..."
        else
            echo 'Waiting for elasticsearch to start...'
        fi
        sleep 1
    done
    if [ "$i" = 0 ]; then
        echo >&2 'Could not connect to the elasticsearch'
        echo "$output"
        retirn 1
    fi
    echo 'Elasticsearch started successfully'
    es_started="1"
    return 0
}

run_maintenance_script_if_needed () {
    if [ -f "$MW_VOLUME/$1.info" ]; then
        update_info="$(cat "$MW_VOLUME/$1.info" 2>/dev/null)"
    else
        update_info=""
    fi

    if [[ "$update_info" != "$2" && -n "$2" && "${2: -1}" != '-' || "$2" == "always" ]]; then
        wait_database_started "$MW_DB_INSTALLDB_USER" "$MW_DB_INSTALLDB_PASS"
        if [[ "$1" == *CirrusSearch* ]]; then wait_elasticsearch_started; fi

        i=3
        while [ -n "${!i}" ]
        do
            if [ ! -f "$(echo "${!i}" | awk '{print $1}')" ]; then
                echo >&2 "Maintenance script does not exit: ${!i}"
                return 0;
            fi
            echo "Run maintenance script: ${!i}"
            runuser -c "php ${!i}" -s /bin/bash "$WWW_USER"
            i=$((i+1))
        done

        echo "Successful updated: $2"
        echo "$2" > "$MW_VOLUME/$1.info"
    else
        echo "$1 is up to date: $2."
    fi
}

run_script_if_needed () {
    if [ -f "$MW_VOLUME/$1.info" ]; then
        update_info="$(cat "$MW_VOLUME/$1.info" 2>/dev/null)"
    else
        update_info=""
    fi

    if [[ "$update_info" != "$2" && -n "$2" && "${2: -1}" != '-' ]]; then
        wait_database_started "$MW_DB_INSTALLDB_USER" "$MW_DB_INSTALLDB_PASS"
        if [[ "$1" == *CirrusSearch* ]]; then wait_elasticsearch_started; fi
        echo "Run script: $3"
        eval "$3"

        cd "$MW_HOME"

        echo "Successful updated: $2"
        echo "$2" > "$MW_VOLUME/$1.info"
    else
        echo "$1 is skipped: $2."
    fi
}

cd "$MW_HOME"

# If there is no LocalSettings.php
if [ ! -e "$MW_VOLUME/LocalSettings.php" ] && [ ! -e "$MW_HOME/LocalSettings.php" ]; then
    echo "There is no LocalSettings.php"

    for x in MW_DB_INSTALLDB_USER MW_DB_INSTALLDB_PASS
    do
        if [ -z "${!x}" ]; then
            echo >&2 "Variable $x must be defined";
            exit 1;
        fi
    done

    wait_database_started "$MW_DB_INSTALLDB_USER" "$MW_DB_INSTALLDB_PASS"

	# Check that the database and table exists (docker creates an empty database)
	tables_count=$(mysql -h db -u"$MW_DB_INSTALLDB_USER" -p"$MW_DB_INSTALLDB_PASS" -e "SELECT count(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$MW_DB_NAME'" | sed -n 2p)
    if [[ $tables_count -gt 0 ]] ; then
        echo "Database exists. Create a symlink to DockerSettings.php as LocalSettings.php"
        ln -s "$MW_HOME/DockerSettings.php" "$MW_VOLUME/LocalSettings.php"
    else
        echo "Create database and LocalSettings.php using maintenance/install.php"
        php maintenance/install.php \
            --confpath "$MW_VOLUME" \
            --dbserver "db" \
            --dbtype "mysql" \
            --dbname "$MW_DB_NAME" \
            --dbuser "$MW_DB_USER" \
            --dbpass "$MW_DB_PASS" \
            --installdbuser "$MW_DB_INSTALLDB_USER" \
            --installdbpass "$MW_DB_INSTALLDB_PASS" \
            --scriptpath "/w" \
            --lang "$MW_SITE_LANG" \
            --pass "$MW_ADMIN_PASS" \
            --skins "" \
            "$MW_SITE_NAME" \
            "$MW_ADMIN_USER"

        # Append inclusion of DockerSettings.php
        echo "@include('DockerSettings.php');" >> "$MW_VOLUME/LocalSettings.php"
    fi
fi

if [ ! -e "$MW_HOME/LocalSettings.php" ]; then
    ln -s "$MW_VOLUME/LocalSettings.php" "$MW_HOME/LocalSettings.php"
fi

jobrunner() {
    sleep 3
    if [ "$MW_ENABLE_JOB_RUNNER" = true ]; then
        echo Run Jobs
        runuser -c /mwjobrunner.sh -s /bin/bash "$WWW_USER"
    else
        echo Job runner is disabled
    fi
}

transcoder() {
    sleep 3
    if [ "$MW_ENABLE_TRANSCODER" = true ]; then
        echo Run transcoder
        runuser -c /mwtranscoder.sh -s /bin/bash "$WWW_USER"
    else
        echo Transcoder disabled
    fi
}

sitemapgen() {
    sleep 3
    if [ "$MW_ENABLE_SITEMAP_GENERATOR" = true ]; then
        echo Run sitemap generator
        runuser -c /mwsitemapgen.sh -s /bin/bash "$WWW_USER"
    else
        echo Sitemap generator is disabled
    fi
}

run_autoupdate () {
    echo 'Check for the need to run maintenance scripts'
    ### maintenance/update.php
    # run_maintenance_script_if_needed 'maintenance_update' "$MW_VERSION-$MW_CORE_VERSION-$MW_MAINTENANCE_UPDATE-$MW_LOAD_SKINS-$MW_LOAD_EXTENSIONS" \
    #    'maintenance/update.php --quick'

    run_maintenance_script_if_needed 'maintenance_update' "always" \
        'maintenance/update.php --quick'

    run_maintenance_script_if_needed 'maintenance_semantic_updateEntityCollation' "always" \
        'extensions/SemanticMediaWiki/maintenance/updateEntityCollation.php'

    run_maintenance_script_if_needed 'maintenance_semantic_updateEntityCountMap' "always" \
        'extensions/SemanticMediaWiki/maintenance/updateEntityCountMap.php'

    ### CirrusSearch
    if [ "$MW_SEARCH_TYPE" == 'CirrusSearch' ]; then
        run_maintenance_script_if_needed 'maintenance_CirrusSearch_updateConfig' "${EXTRA_MW_MAINTENANCE_CIRRUSSEARCH_UPDATECONFIG}${MW_MAINTENANCE_CIRRUSSEARCH_UPDATECONFIG}${MW_VERSION}" \
            'extensions/CirrusSearch/maintenance/UpdateSearchIndexConfig.php --reindexAndRemoveOk --indexIdentifier now' \
            'extensions/CirrusSearch/maintenance/Metastore.php --upgrade'

        run_maintenance_script_if_needed 'maintenance_CirrusSearch_forceIndex' "${EXTRA_MW_MAINTENANCE_CIRRUSSEARCH_FORCEINDEX}${MW_MAINTENANCE_CIRRUSSEARCH_FORCEINDEX}${MW_VERSION}" \
            'extensions/CirrusSearch/maintenance/ForceSearchIndex.php --skipLinks --indexOnSkip' \
            'extensions/CirrusSearch/maintenance/ForceSearchIndex.php --skipParse'
    fi

    ### cldr extension
    if [ -n "$MW_SCRIPT_CLDR_REBUILD" ]; then
    run_script_if_needed 'script_cldr_rebuild' "$MW_VERSION-$MW_SCRIPT_CLDR_REBUILD" \
        "set -x; cd $MW_HOME/extensions/cldr && wget -q http://www.unicode.org/Public/cldr/latest/core.zip && unzip -q core.zip -d core && php rebuild.php && set +x;"

        if [ -n "$MW_MAINTENANCE_ULS_INDEXER" ]; then
            ### UniversalLanguageSelector extension
            run_maintenance_script_if_needed 'maintenance_ULS_indexer' "$MW_VERSION-$MW_SCRIPT_CLDR_REBUILD-$MW_MAINTENANCE_ULS_INDEXER" \
                'extensions/UniversalLanguageSelector/data/LanguageNameIndexer.php'
        fi
    fi

    ### Flow extension
#    if [ -n "$MW_FLOW_NAMESPACES" ]; then
# https://phabricator.wikimedia.org/T172369
#        if [ "$MW_SEARCH_TYPE" == 'CirrusSearch' ]; then
#            # see https://www.mediawiki.org/wiki/Flow/Architecture/Search
#            run_maintenance_script_if_needed 'maintenance_FlowSearchConfig_CirrusSearch' "$MW_MAINTENANCE_CIRRUSSEARCH_UPDATECONFIG" \
#                'extensions/Flow/maintenance/FlowSearchConfig.php'
#        fi
#    fi

    jobrunner &
    transcoder &
    sitemapgen &

    echo Auto-update completed
}

########## Run maintenance scripts ##########
if [ "$MW_AUTOUPDATE" = true ]; then
    run_autoupdate &
else
    echo "Auto update script is disabled, \$MW_AUTOUPDATE is $MW_AUTOUPDATE";
    jobrunner &
    transcoder &
    sitemapgen &
fi

########## Run Monit ##########
if [ -n "$MONIT_SLACK_HOOK" ]; then
    echo "Starting monit.."
    monit -I -c /etc/monitrc &
else
    echo "Skip monit (MONIT_SLACK_HOOK is not defined)"
fi

# Make sure we're not confused by old, incompletely-shutdown httpd
# context after restarting the container.  httpd won't start correctly
# if it thinks it is already running.

############### Run Apache ###############
# Make sure we're not confused by old, incompletely-shutdown httpd
# context after restarting the container.  httpd won't start correctly
# if it thinks it is already running.
rm -rf /run/httpd/* /tmp/httpd*

exec /usr/sbin/apachectl -DFOREGROUND
