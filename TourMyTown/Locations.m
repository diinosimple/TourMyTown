//
//  Locations.m
//  TourMyTown
//
//  Created by Michael Katz on 8/15/13.
//  Copyright (c) 2013 mikekatz. All rights reserved.
//

#import "Locations.h"
#import "Location.h"

static NSString* const kBaseURL = @"http://diino-simple-is-best.herokuapp.com/";
static NSString* const kLocations = @"locations";
static NSString* const kFiles = @"files";


@interface Locations ()
@property (nonatomic, strong) NSMutableArray* objects;
@end

@implementation Locations

- (id)init
{
    self = [super init];
    if (self) {
        _objects = [NSMutableArray array];
    }
    return self;
}

- (NSArray*) filteredLocations
{
    return [self objects];
}

- (void) addLocation:(Location*)location
{
    [self.objects addObject:location];
}

- (void)loadImage:(Location*)location
{
    //Just like when loading a specific location, the image’s id is appended to the path along with the name of the endpoint: files.
    NSURL* url = [NSURL URLWithString:[[kBaseURL stringByAppendingPathComponent:kFiles] stringByAppendingPathComponent:location.imageId]]; //1
    
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
    
    //The download task is the third kind of NSURLSession; it downloads a file to a temporary location and returns a URL to that location, rather than the raw NSData object, as the raw object can be rather large.
    NSURLSessionDownloadTask* task = [session downloadTaskWithURL:url completionHandler:^(NSURL *fileLocation, NSURLResponse *response, NSError *error) { //2
        if (!error) {
            //The temporary location is only guaranteed to be available during the completion block’s execution, so you must either load the file into memory, or move it somewhere else.
            NSData* imageData = [NSData dataWithContentsOfURL:fileLocation]; //3
            UIImage* image = [UIImage imageWithData:imageData];
            if (!image) {
                NSLog(@"unable to build image");
            }
            location.image = image;
            if (self.delegate) {
                [self.delegate modelUpdated];
            }
        }
    }];
    //Like all NSURLSession tasks, you start the task with resume.
    [task resume]; //4
}

/*You iterate through the array of JSON dictionaries and create a new Location object for each item.*/
- (void)parseAndAddLocations:(NSArray*)locations toArray:(NSMutableArray*)destinationArray
{
    for (NSDictionary* item in locations) {
        Location* location = [[Location alloc] initWithDictionary:item];
        [destinationArray addObject:location];
        
        if (location.imageId) { //1
            [self loadImage:location];
        }
    }
    
    if (self.delegate) {
        [self.delegate modelUpdated];
    }
}

- (void)import
{
    /*The most important bits of information are the URL and request headers. 
     The URL is simply the result of concatenating the base URL with the “locations” collections.*/
    NSURL* url = [NSURL URLWithString:[kBaseURL stringByAppendingPathComponent:kLocations]];
    
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    
    /*You’re using GET since you’re reading data from the server. GET is the default method so it’s not necessary to specify it here, but it’s nice to include it for completeness and clarity.*/
    request.HTTPMethod = @"GET";
    
    /*The server code uses the contents of the Accept header as a hint to which type of response to send. By specifying that your request will accept JSON as a response, the returned bytes will be JSON instead of the default format of HTML.*/
    [request addValue:@"application/json" forHTTPHeaderField:@"Accept"];
    
    /*Here you create an instance of NSURLSession with a default configuration.*/
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
    
    /*A data task is your basic NSURLSession task for transferring data from a web service. There are also specialized upload and download tasks that have specialized behavior for long-running transfers and background operation. 
     A data task runs asynchronously on a background thread, so you use a callback block to be notified when the operation completes or fails.*/
    NSURLSessionDataTask* dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil) {
            
            /*The completion handler checks for any errors; if it finds none it tries to deserialize the data using a NSJSONSerialization class method.*/
            NSArray* responseArray = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            
            /*Assuming the return value is an array of locations, parseAndAddLocations: parses the objects and notifies the view controller with the updated data.*/
            [self parseAndAddLocations:responseArray toArray:self.objects];
        }
    }];
    
    /*Oddly enough, data tasks are started with the resume message. When you create an instance of NSURLSessionTask it starts in the “paused” state, so to start it you simply call resume.*/
    [dataTask resume];
}


- (void) runQuery:(NSString *)queryString
{
    //You add the query string generated in queryRegion: to the end of the locations endpoint URL.
    NSString* urlStr = [[kBaseURL stringByAppendingPathComponent:kLocations] stringByAppendingString:queryString]; //1
    NSURL* url = [NSURL URLWithString:urlStr];
    
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request addValue:@"application/json" forHTTPHeaderField:@"Accept"];
    
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDataTask* dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil) {
            //You also discard the previous set of locations and replace them with the filtered set returned from the server. This keeps the active results at a manageable level.
            [self.objects removeAllObjects]; //2
            NSArray* responseArray = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSLog(@"received %d items", responseArray.count);
            [self parseAndAddLocations:responseArray toArray:self.objects];
        }
    }];
    [dataTask resume];
}

- (void) queryRegion:(MKCoordinateRegion)region
{
    //note assumes the NE hemisphere. This logic should really check first.
    //also note that searches across hemisphere lines are not interpreted properly by Mongo
    //These four lines calculate the map-coordinates of the two diagonal corners of the bounding box.
    CLLocationDegrees x0 = region.center.longitude - region.span.longitudeDelta; //1
    CLLocationDegrees x1 = region.center.longitude + region.span.longitudeDelta;
    CLLocationDegrees y0 = region.center.latitude - region.span.latitudeDelta;
    CLLocationDegrees y1 = region.center.latitude + region.span.latitudeDelta;
    
    //This defines a JSON structure for the query using MongoDB’s specific query language. A query with a $geoWithin key specifies the search criteria as everything located within the structure defined by the provided value. $box specifies the rectangle defined by the provided coordinates and supplied as an array of two longitude-latitude pairs at opposite corners.
    NSString* boxQuery = [NSString stringWithFormat:@"{\"$geoWithin\":{\"$box\":[[%f,%f],[%f,%f]]}}",x0,y0,x1,y1]; //2
    
    //boxQuery just defines the criteria value; you also have to provide the search key field along boxQuery as a JSON object to MongoDB.
    NSString* locationInBox = [NSString stringWithFormat:@"{\"location\":%@}", boxQuery]; //3
    
    //You then escape the entire query object as it will be posted as part of a URL; you need to ensure that that internal quotes, brackets, commas, and other non-alphanumeric bits won’t be interpreted as part of the HTTP query parameter. CFURLCreateStringByAddingPercentEscapes is a CoreFoundation method for creating URL-encoded strings.
    NSString* escBox = (NSString *)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL,
                                                                                             (CFStringRef) locationInBox,
                                                                                             NULL,
                                                                                             (CFStringRef) @"!*();':@&=+$,/?%#[]{}",
                                                                                             kCFStringEncodingUTF8)); //4
    
    //The final piece of the string building sets the entire escaped MongoDB query as the query value in the URL.
    NSString* query = [NSString stringWithFormat:@"?query=%@", escBox]; //5
    
    //You then request matching values from the server with your new query.
    [self runQuery:query]; //7
}

- (void) persist:(Location*)location
{
    if (!location || location.name == nil || location.name.length == 0) {
        return; //input safety check
    }
    
    //if there is an image, save it first
    //If there is an image but no image id, then the image hasn’t been saved yet.
    if (location.image != nil && location.imageId == nil) { //1
        //Call the new method to save the image, and exits.
        [self saveNewLocationImageFirst:location]; //2
        return;
    }
    
    
    NSString* locations = [kBaseURL stringByAppendingPathComponent:kLocations];
    
    BOOL isExistingLocation = location._id != nil;
    
    /*There are two endpoints for saving an object: /locations when you’re adding a new location, and /locations/_id when updating an existing location that already has an id.*/
    NSURL* url = isExistingLocation ? [NSURL URLWithString:[locations stringByAppendingPathComponent:location._id]] :
    [NSURL URLWithString:locations];
    
    /*The request uses either PUT for existing objects or POST for new objects. The server code calls the appropriate handler for the route rather than using the default GET handler.*/
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = isExistingLocation ? @"PUT" : @"POST";
    
    /*Because you’re updating an entity, you provide an HTTPBody in your request which is an instance of NSData object created by the NSJSONSerialization class.*/
    NSData* data = [NSJSONSerialization dataWithJSONObject:[location toDictionary] options:0 error:NULL];
    request.HTTPBody = data;
    
    /*Instead of an Accept header, you’re providing a Content-Type. This tells the bodyParser on the server how to handle the bytes in the body.*/
    [request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; //4
    
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
    
    /*The completion handler once again takes the modified entity returned from the server, parses it and adds it to the local collection of Location objects.*/
    NSURLSessionDataTask* dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) { //5
        if (!error) {
            NSArray* responseArray = @[[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]];
            [self parseAndAddLocations:responseArray toArray:self.objects];
        }
    }];
    [dataTask resume];
}

- (void) saveNewLocationImageFirst:(Location*)location
{
    //The URL is the files endpoint.
    NSURL* url = [NSURL URLWithString:[kBaseURL stringByAppendingPathComponent:kFiles]]; //1
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    
    //Using POST triggers handleUploadRequest of fileDriver to save the file.
    request.HTTPMethod = @"POST"; //2
    
    //Setting the content type ensures the file will be saved appropriately on the server. The Content-Type header is important for determining the file extension on the server.
    [request addValue:@"image/png" forHTTPHeaderField:@"Content-Type"]; //3
    
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
    
    //UIImagePNGRepresentation turns an instance of UIImage into PNG file data.
    NSData* bytes = UIImagePNGRepresentation(location.image); //4
    
    //NSURLSessionUploadTask lets you send NSData to the server in the request itself. For example, upload tasks automatically set the Content-Length header based on the data length. Upload tasks also report progress and can run in the background, but neither of those features is used here.
    NSURLSessionUploadTask* task = [session uploadTaskWithRequest:request fromData:bytes completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) { //5
        if (error == nil && [(NSHTTPURLResponse*)response statusCode] < 300) {
            //The response contains the new file data entity, so you save _id along with the location object for later retrieval.
            NSDictionary* responseDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            location.imageId = responseDict[@"_id"]; //6
            //Once the image is saved and _id recorded, then the main Location entity can be saved to the server.
            [self persist:location]; //7
        }
    }];
    [task resume];
}
@end