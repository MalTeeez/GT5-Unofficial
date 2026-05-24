#!/bin/bash
set -ex

JSON_FILE=$1
GRADLE_DIR=~/.gradle
INIT_GRADLE=$GRADLE_DIR/init.gradle

# Exit early if there are no dependencies
DEP_COUNT=$(jq '.dependencies | length' "$JSON_FILE")
if [ "$DEP_COUNT" -eq 0 ]; then
    echo "No dependencies found, failure was probably not due to a required dependency. Failing to propagate initial failure."
    exit 1
fi

# Write init.gradle header to user gradle dir (first as a temp file since it will parsed w. just this)
mkdir -p $GRADLE_DIR
cat > $INIT_GRADLE.tmp << 'EOF'
allprojects {
    repositories {
        mavenLocal()
    }
    configurations.all {
        resolutionStrategy.eachDependency { details ->
EOF

# Process each dependency
jq -c '.dependencies[]' $JSON_FILE | while read -r dep; do
    JAR_PATH=$(echo $dep | jq -r '.jar_path')
    REPO_URL=$(echo $dep | jq -r '.repo_url')
    COMMIT_SHA=$(echo $dep | jq -r '.commit_sha')

    PREV_DIR=$(pwd)
    REPO_NAME=$(basename $REPO_URL .git)
    WORK_DIR=$(mktemp -d)/$REPO_NAME
    mkdir -p $WORK_DIR
    echo "Processing $REPO_URL @ $COMMIT_SHA (in $WORK_DIR)"
    cd $WORK_DIR

    # Shallow clone and checkout
    git clone --depth 1 $REPO_URL .
    git fetch --depth 1 origin $COMMIT_SHA
    git checkout $COMMIT_SHA

    # Get coordinates
    PROPS=$(./gradlew -q :properties 2>/dev/null)
    GROUP=$(echo "$PROPS" | grep '^group:' | awk '{print $2}')
    PROJECT=$REPO_NAME
    VERSION=$(echo "$PROPS" | grep '^version:' | awk '{print $2}')

    echo "Coordinates of local maven result: $GROUP:$PROJECT:$VERSION"

    # Go back to original dir & clean up workdir
    cd $PREV_DIR
    rm -rf $WORKDIR

    # Install jar into mavenLocal
    MAVEN_PATH="${GROUP//.//}/$PROJECT/$VERSION"
    mkdir -p ~/.m2/repository/$MAVEN_PATH
    cp $JAR_PATH ~/.m2/repository/$MAVEN_PATH/$PROJECT-$VERSION-dev.jar

    # Write minimal POM so Gradle can find it
    cat > ~/.m2/repository/$MAVEN_PATH/$PROJECT-$VERSION.pom << POMEOF
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <groupId>$GROUP</groupId>
  <artifactId>$PROJECT</artifactId>
  <version>$VERSION</version>
</project>
POMEOF

    # Append override to init.gradle
    cat >> $INIT_GRADLE.tmp << EOF
            if (details.requested.module.toString() == '${GROUP}:${PROJECT}') {
                details.useVersion '${VERSION}'
                details.because 'PR dependency override'
            }
EOF

    rm -rf $WORK_DIR
done

# Close init.gradle
cat >> $INIT_GRADLE.tmp << 'EOF'
        }
    }
}
EOF

# Rename to actual now that its parseable
mv $INIT_GRADLE.tmp $INIT_GRADLE