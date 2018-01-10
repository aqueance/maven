#!/usr/bin/env bash -e

function die {
    echo "$1" >&2
    exit -1;
}

[ ! -d .git ] && die "This is not a Git repository."

# Finds the physical directory containing this very script
# http://stackoverflow.com/a/246128
function script_directory {
    local SOURCE="${BASH_SOURCE[0]}"

    while [ -h "$SOURCE" ]; do                              # resolve $SOURCE until the file is no longer a symlink
        local DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
        local SOURCE="$(readlink "$SOURCE")"
        [[ ! "$SOURCE" =~ ^/ ]] && SOURCE="$DIR/$SOURCE"    # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done

    echo "$(cd -P "$(dirname "$SOURCE")" && pwd)"
}

LOCAL_MAVEN="${HOME}/.m2"

CATALOG=archetype-catalog.xml
REPO=repository
JAVADOC=apidocs

LOCAL_REPO="${LOCAL_MAVEN}/${REPO}"
LOCAL_CATALOG="${LOCAL_MAVEN}/${CATALOG}"

STAGING="$(script_directory)"
STAGING_REPO="${STAGING}/${REPO}"
STAGING_JAVADOC="${STAGING}/${JAVADOC}"
STAGING_CATALOG="${STAGING}/${CATALOG}"

STAGING_ARCHETYPES="${STAGING}/archetypes"
mkdir -p "${STAGING_ARCHETYPES}"

function projectId {
    local POM=pom.xml

    [ -r ${POM} ] || die "Root POM not found: ${POM}."

    # Use awk to parse the root POM for the groupId and artifactId
    local POM_FILTER=pom-filter.awk
    trap "rm -f ${POM_FILTER}" EXIT

    # some local variables for the awk script
    local MV=modelVersion GP=groupId AF=artifactId

    cat >${POM_FILTER} <<END_SCRIPT
{
    FS = "<|>";

    if (\$2 == "${MV}") { ${MV} = 1; ${GP} = ""; ${AF} = ""; next; }
    if (${MV} == 1 && \$2 == "${GP}") { ${GP} = \$3; next; }
    if (${MV} == 1 && \$2 == "${AF}") { ${AF} = \$3; next; }
    if (${GP} != "" && ${AF} != "") { print ${GP} "." ${AF}; exit; }
}
END_SCRIPT

    # Do the extraction
    awk -f ${POM_FILTER} ${POM}
}

function version {
    local POM=pom.xml

    [ -r ${POM} ] || die "Root POM not found: ${POM}."

    # Use awk to parse the root POM for the version
    local POM_FILTER=pom-filter.awk
    trap "rm -f ${POM_FILTER}" EXIT

    # some local variables for the awk script
    local MV=modelVersion VS=version

    cat >${POM_FILTER} <<END_SCRIPT
{
    FS = "<|>";

    if (\$2 == "${MV}") { ${MV} = 1; ${VS} = ""; next; }
    if (${MV} == 1 && \$2 == "${VS}") { ${VS} = \$3; next; }
    if (${VS} != "") { print ${VS}; exit; }
}
END_SCRIPT

    # Do the extraction
    awk -f ${POM_FILTER} ${POM}
}

function name {
    local POM=pom.xml

    [ -r ${POM} ] || die "Root POM not found: ${POM}."

    # Use awk to parse the root POM for the name
    local POM_FILTER=pom-filter.awk
    trap "rm -f ${POM_FILTER}" EXIT

    # some local variables for the awk script
    local MV=modelVersion NM=name

    cat >${POM_FILTER} <<END_SCRIPT
{
    FS = "<|>";

    if (\$2 == "${MV}") { ${MV} = 1; ${NM} = ""; next; }
    if (${MV} == 1 && \$2 == "${NM}") { ${NM} = \$3; next; }
    if (${NM} != "") { print ${NM}; exit; }
}
END_SCRIPT

    # Do the extraction
    awk -f ${POM_FILTER} ${POM}
}

COMMIT=$(git rev-parse HEAD)
[ -z "${COMMIT}" ] && die "Last commit could not be identified."

PROJECT_ID=$(projectId)
[ -z "${PROJECT_ID}" ] && die "Project ID could not be identified."

NAME="$(name)"
[ -z "${NAME}" ] && die "Name could not be identified."

VERSION=$(version)
[ -z "${VERSION}" ] && die "Version could not be identified."

LOG_DIR="${STAGING}/logs"
mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/${PROJECT_ID}-${VERSION}-build-log.txt"
echo "Build log: ${LOG_FILE}"

function prepare {
    local BRANCH=$(git branch | grep '*' | cut -d\  -f2)
    [ "${BRANCH}" == "master" ] || die "Deployment aborted on branch ${BRANCH}"

    [ -z "$(git status --porcelain -uno)" ] || die "There are uncommitted changes"

    [ -d "${STAGING}" ] || git clone git@github.com:aqueance/maven.git "${STAGING}"
    [ -d "${STAGING}" ] && [ ! -d "${STAGING}/.git" ] && die "${STAGING} is not a Git repository."

    [ -z "$(cd "${STAGING}"; git status --porcelain -uno)" ] || die "Staging repository not pristine"

    echo "Staging ${NAME} ${VERSION} (${PROJECT_ID}) commit ${COMMIT} at $(date)" | tee "${LOG_FILE}"
}

function artifacts {
    echo "Generating artifacts to ${STAGING_REPO}" | tee -a "${LOG_FILE}"

    # We are NOT using the deploy goal as it adds timestamp prefixes and such (Reproducible snapshot builds? Haha, good one.)
    #mvn deploy -Ddistribution "-DaltDeploymentRepository=staging::default::file://$(pwd)/${STAGING_REPO}"

    # Install the artifacts with checksum
    mvn clean install -Ddistribution -DcreateChecksum=true >>"${LOG_FILE}"

    local PROJECT_DIR=$(echo ${PROJECT_ID} | tr '.' '/')
    [ -d ""${LOCAL_REPO}/${PROJECT_DIR}"" ] || die "Artifacts not found: ${LOCAL_REPO}/${PROJECT_DIR}"

    # Copy the artifacts to the staging area
    (cd "${LOCAL_MAVEN}"; tar cJf - "${REPO}/${PROJECT_DIR}") | (cd "${STAGING}"; tar xJvf - 2>>"${LOG_FILE}")
}

function archetype_fragment {
    echo "${1}-${CATALOG}-fragment"
}

function archetypes {
    [ -r "${LOCAL_CATALOG}" ] || die "Archetype catalog not found: ${LOCAL_CATALOG}."

    echo "Generating archetype catalog in ${STAGING}" | tee -a "${LOG_FILE}"

    # We are NOT using the archetype plugin as it fails to set the archetype description
    #mvn -N archetype:crawl "-Drepository=${STAGING_REPO}"

    # Use awk to parse the local archetype catalog and extract the archetypes by this project
    local CATALOG_FILTER=catalog-filter.awk
    local PROLOGUE_FILTER=prologue-filter.awk
    local EPILOGUE_FILTER=epilogue-filter.awk
    trap "rm -f ${CATALOG_FILTER} ${PROLOGUE_FILTER} ${EPILOGUE_FILTER}" EXIT

    # some local variables for the awk script
    local ATS=archetypes AT=archetype GP=groupId AF=artifactId VS=version DS=description

    cat >${CATALOG_FILTER} <<END_SCRIPT
{
    FS = "<|>";

    if (\$2 == "${AT}") { ${AT} = 1; I = \$1; II = I "  "; ${GP} = ""; AF = ""; ${VS} = ""; ${DS} = ""; next; }
    if (${AT} == 1 && \$2 == "${GP}") { ${GP} = \$3; next; }
    if (${AT} == 1 && \$2 == "${AF}") { ${AF} = \$3; next; }
    if (${AT} == 1 && \$2 == "${VS}") { ${VS} = \$3; next; }
    if (${AT} == 1 && \$2 == "${DS}") { ${DS} = \$3; next; }
    if (\$2 == "/${AT}") { ${AT} = 0; if (match(${GP}, /^${PROJECT_ID}/)) { print I "<${AT}>\n" II "<${GP}>" ${GP} "</${GP}>\n" II "<${AF}>" ${AF} "</${AF}>\n" II "<${VS}>" ${VS} "</${VS}>\n" II "<${DS}>" ${DS} "</${DS}>\n" I "</${AT}>"; } next; }
}
END_SCRIPT

    # Extract the XML prologue before the archetype tags
    cat >${PROLOGUE_FILTER} <<END_SCRIPT
{
    FS = "<|>";

    if (\$2 == "${AT}") { ${AT} = 1; exit; }

    print;
}
END_SCRIPT

    # Extract the XML epilogue after the archetype tags
    cat >${EPILOGUE_FILTER} <<END_SCRIPT
{
    FS = "<|>";

    if (\$2 == "/${ATS}") ${ATS} = 1;
    if (${ATS} != 1) next;

    print;
}
END_SCRIPT

    local SOURCE="${LOCAL_CATALOG}"
    local TARGET="${STAGING_CATALOG}"

    local FRAGMENT="${STAGING_ARCHETYPES}/$(archetype_fragment "${PROJECT_ID}-${VERSION}")"

    awk -f ${CATALOG_FILTER} "${SOURCE}" >"${FRAGMENT}"             # Extract this project's archetypes
    awk -f ${PROLOGUE_FILTER} "${SOURCE}" >"${TARGET}"              # Add the prologue
    (cd "${STAGING_ARCHETYPES}"; cat $(archetype_fragment \*)) >>"${TARGET}"   # Add all archetypes
    awk -f ${EPILOGUE_FILTER} "${SOURCE}" >>"${TARGET}"             # Add the epilogue

    echo "Found $(cat "${FRAGMENT}" | grep '<archetype>' | wc -l | tr -d ' ') archetypes" | tee -a "${LOG_FILE}"
}

function javadoc {
    local APIDOCS="${STAGING_JAVADOC}/${PROJECT_ID}-${VERSION}"

    echo "Generating API docs to ${APIDOCS}" | tee -a "${LOG_FILE}"

    # Generate the API documentation
    mvn javadoc:aggregate >>"${LOG_FILE}"

    mkdir -p "${APIDOCS}"

    (cd target/site/apidocs; tar cJf - .) | (cd "${APIDOCS}"; tar xJvf - 2>>"${LOG_FILE}")

    # Record the project ID to which this API documentation belongs
    local API_ID="${NAME} ${VERSION} $(date)"
    local API_ID_FILE=project-id.txt
    echo "${API_ID}" >"${APIDOCS}/${API_ID_FILE}"

    # Generate the index.html for all generated API docs
    cat >"${STAGING_JAVADOC}/index.html" <<END_FILE
<!doctype html>
<head>
    <title>API documentation</title>
    <link rel="stylesheet" href="../css/page.css"/>
</head>
<body>
$(cd "${STAGING_JAVADOC}"; for DIR in */; do [ -r "${DIR}/${API_ID_FILE}" ] && echo "<h4><a href=\"${DIR}\">$(cat "${DIR}/${API_ID_FILE}")</a><h4>"; done)
</body>
END_FILE
}

function upload {
    echo "Committing changes" | tee -a "${LOG_FILE}"

    local COMMENT="${NAME} ${VERSION} ${COMMIT} $(date)"
    (cd "${STAGING_REPO}"; git add -A; git commit -m "${COMMENT}" -q)
}

function complete {
    echo "Staging done"
}

prepare
artifacts
javadoc
archetypes
upload
complete
