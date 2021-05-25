systemctl restart pyramidAgent && echo "pyramidAgent restarted" || echo "pyramidAgent restart failed"
systemctl restart pyramidFs && echo "pyramidFileSystem restarted" || echo "pyramidFileSystem restart failed"
systemctl restart pyramidIMDB && echo "pyramidIMDB restarted" || echo "pyramidIMDB restart failed"
systemctl restart pyramidRTE && echo "pyramidRuntime restarted" || echo "pyramidRuntime restart failed"
systemctl restart pyramidRTR && echo "pyramidRouter restarted" || echo "pyramidRouter restart failed"
systemctl restart pyramidWeb && echo "pyramidWeb restarted" || echo "pyramidWeb restart failed"
systemctl restart pyramidAI && echo "pyramidAI restarted" || echo "pyramidAI restart failed"
systemctl restart pyramidTE && echo "pyramidTask restarted" || echo "pyramidTask restart failed"

