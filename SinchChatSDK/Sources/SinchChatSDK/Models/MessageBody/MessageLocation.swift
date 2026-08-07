public struct MessageLocation: MessageBody {
    
    public var label: String
    public var title: String
    public var latitude: Double
    public var longitude: Double
    public var sendDate: Int64?
    public var isExpanded: Bool = false

    public func getReadMore(maxCount: Int, textToAdd: String ) -> String {
        
        if title.count > maxCount && !isExpanded {
           
            return title.prefix(maxCount) + "... " + "\(textToAdd)"
            
        }
        
        return title
      
    }
}
