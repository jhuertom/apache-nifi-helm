set -e
USER_ID="38e35829-435d-3be4-83b6-784cb560e855"
ROOT_GROUP_ID="23a6b22d-5044-3b80-b1e1-3148bd2732a1"

if [ -n "$USER_ID" ]; then
  # Simulating kubectl exec string construction
  # The outer shell is "sh"
  # The inner command is bash -c "..."
  
  # Note: In the real file, there are NO backslashes for $RESOURCE, $ACTION, etc.
  
  CMD="
      USER_ID='$USER_ID'
      ROOT_GROUP_ID='$ROOT_GROUP_ID'
      AUTH_FILE='/opt/nifi/nifi-current/persistent_conf/authorizations.xml'
      
      cp \"\$AUTH_FILE\" \"\${AUTH_FILE}.backup\"
      
      add_user_to_policy() {
        RESOURCE=\$1
        ACTION=\$2
        
        # In real file line 82:
        POLICY_ID=$(xmlstarlet sel -t -v \"//policy[@resource='$RESOURCE' and @action='$ACTION']/@identifier\" \"$AUTH_FILE\")
        
        if [ -n \"\$POLICY_ID\" ]; then
           echo exists
        fi
      }
  "
  echo "$CMD"
fi
