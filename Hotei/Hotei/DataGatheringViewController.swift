//
//  DataGatheringViewController.swift
//  Hotei
//
//  Created by Ryan Dowse on 11/03/2017.
 
//  Copyright © 2017 AppBee. All rights reserved.
//

import UIKit
import NotificationCenter
import UserNotifications

class DataGatheringViewController: UIViewController {

    // Storage for data points
    struct hrData{
        var time:Double
        var label:Int
        var mean_hr:Double   // Mean HR
        var hrv:Double
        
        init(time:Double,label:Int,hr:Double,hrv:Double) {
            self.mean_hr = hr
            self.time = time
            self.label = label
            self.hrv = hrv
        }
        
        static func getCSVHeader()->String{
            return "time,stress level,hr,hrv\n"
        }
        
        func getCSVFormat()->String{
            return "\(self.label),\(self.mean_hr),\(self.hrv)\n"
        }
    }
    
    // Wrapper for opencv in objc
    let opencv_wrapper = OpenCVWrapper()
    var readyToPredict:Bool = false
    var loaded:Bool = false
    
    // Timer
    let timeIntervalNotification:Double = 30//60*5
    
    // Misc Params
    var dataBuffer:[hrData] = []    // Contains all data samples stored
    var hm:HeartMonitor             // For bluetooth connection to heartmonitor device
    
    /*
     *  Mark - UI outlets
     */
    
    @IBOutlet weak var meanHRLabel: UILabel!
    @IBOutlet weak var hrLabel: UILabel!
    @IBOutlet weak var hrvLabel: UILabel!
    @IBOutlet weak var stressStateLabel: UILabel!
    
    @IBOutlet weak var saveButton: UIButton!
    @IBOutlet weak var mlButton: UIButton!
    @IBOutlet weak var stateSwitch: UISwitch!
    
    
    /*
     *  Mark - keypress actions
     */
    
    @IBAction func saveData(_ sender: Any) {
        print("--- Saving data")
        writeFile()
    }
    @IBAction func onTrainPressed(_ sender: Any) {
        print("--- Training SVM model")
        if(dataBuffer.isEmpty){
            print("Databuffer must not be empty for training")
            return
        }
            
        // repackage hrData array for opencv format
        var hr_buff : UnsafeMutablePointer<Double>?
        var hrv_buff : UnsafeMutablePointer<Double>?
        var state_buff : UnsafeMutablePointer<Int32>?
        hr_buff = UnsafeMutablePointer<Double>.allocate(capacity: dataBuffer.count)
        hrv_buff = UnsafeMutablePointer<Double>.allocate(capacity: dataBuffer.count)
        state_buff = UnsafeMutablePointer<Int32>.allocate(capacity: dataBuffer.count)
        
        // assign data

        for index in 0...(dataBuffer.count-1) {
            hr_buff!.advanced(by: index).pointee = dataBuffer[index].mean_hr
            hrv_buff!.advanced(by: index).pointee = dataBuffer[index].hrv
            state_buff!.advanced(by: index).pointee = Int32(dataBuffer[index].label)
        }
        
        // Train svm model
        let image:UIImage = opencv_wrapper.trainSVM(hr_buff, andHRV: hrv_buff, andState: state_buff, andSize: Int32(dataBuffer.count))
        
        // Resize image to fit screen
        let scale:Double = 1;
        let resized_image: UIImage = resizeImage(image: image,
                                                 targetSize: CGSize(width:Double(image.size.width)*scale,
                                                            height:Double(image.size.height)*scale))
        
        // Screen size info
        let screenSize = UIScreen.main.bounds
        let screenWidth = screenSize.width
        let screenHeight = screenSize.height
        
        // Image view to add image to
        let imageView = UIImageView(image: resized_image)
        
        // Position image
        let pos_w = Double((screenWidth-resized_image.size.width)/2)
        let pos_h = Double((screenHeight)/2)
        imageView.frame = CGRect(x: pos_w, y: pos_h,
                                 width: Double(image.size.width)*scale,
                                 height: Double(image.size.height)*scale)
        
        // Flip image horizontally
        imageView.transform = CGAffineTransform(scaleX: 1,y: -1)
        
        // Add image to current view
        view.addSubview(imageView)
        print("--- SVM Model trained")
        
        // HIDDEN LABELS
        /*let neg_image:UIImage = opencv_wrapper.negLabel()
        let pos_image:UIImage = opencv_wrapper.posLabel()
        posLabel = UIImageView(image: pos_image)
        negLabel = UIImageView(image: neg_image)*/
    }
    
    // function for the opencv tutorial SVM
    func exampleSVMPlot(){
        print("--- example SVM")
        
        let image:UIImage = opencv_wrapper.plotData()
        // resize image to fit screen
        let scale = 0.5;
        let resized_image: UIImage = resizeImage(image: image,
                    targetSize: CGSize(width:Double(image.size.width)*scale,
                                       height:Double(image.size.height)*scale))
        let imageView = UIImageView(image: resized_image)
        imageView.frame = CGRect(x: 20, y: 20,
                                 width: Double(image.size.width)*scale,
                                 height: Double(image.size.height)*scale)
        // Add image to current view
        view.addSubview(imageView)
    }
    
    /*
     *  Mark - viewcontroller initialisers
     */
    
    required init?(coder aDecoder: NSCoder) {
        self.hm = HeartMonitor()
        self.dataBuffer.reserveCapacity(1000)
        super.init(coder: aDecoder)
        
        // Search for bluetooth device
        hm.scanForDevices()
        
        // Load initial csv data
        loadFile()
        
        // Timer for stressed notification
        let date = Date().addingTimeInterval(self.timeIntervalNotification)
        let timer = Timer(fireAt: date, interval: self.timeIntervalNotification, target: self, selector:  #selector(resetStateFlag), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
        
        // Observe refresh notification for when features have been recalculated eg. HRV
        NotificationCenter.default.addObserver(self, selector: #selector(DataGatheringViewController.updateData), name: NSNotification.Name(rawValue: "refreshFeatures"), object: nil)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        // Observe refresh notification for when a new HR value is available
        
        NotificationCenter.default.addObserver(self, selector: #selector(DataGatheringViewController.updateLabels), name: NSNotification.Name(rawValue: "refresh"), object: nil)
        UNUserNotificationCenter.current().delegate = self
        readyToPredict = true
        loaded = true
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    /*
     *  Mark - update functions
     */
    
    // receive notification from hrmonitor when there is a value update
    func updateLabels(notification:Notification){
        if(loaded){
        self.hrLabel.text = String(format:"%d",hm.getHR())
        self.hrvLabel.text = String(format:"%.1f",hm.getHRV())
        self.meanHRLabel.text = String(format:"%.1f",hm.getMeanHR())
        }
    }
    
    // called when refreshFeatures notification is received
    func updateData(){
        storeSample()
        if(readyToPredict){
            readyToPredict = false
            predict()
        }
    }

    // store current sample data, continuously called
    func storeSample(){
        print(" ---- STORING SAMPLE ---- ")
        if(self.hm.getHR() == 0 || self.hm.getHRV() == 0 || self.hm.getMeanHR() == 0 ){
            print("--- HR/HRV sample is 0. Sample not stored");
        }
        if let stateSwitch = stateSwitch{
            self.dataBuffer.append(
                hrData(time: NSDate().timeIntervalSince1970,
                       label: stateSwitch.isOn ? 1 : -1,
                       hr: self.hm.getMeanHR(),
                       hrv: self.hm.getHRV())
            )
        } else {
            self.dataBuffer.append(
                hrData(time: NSDate().timeIntervalSince1970,
                       label: -1,
                       hr: self.hm.getMeanHR(),
                       hrv: self.hm.getHRV())
            )
        }
    }
    
    func predict(){
        print("--- Making prediction")
        let predicted_state:Bool = opencv_wrapper.predict(self.hm.getMeanHR(), andHRV: self.hm.getHRV())
        // send notification if predicted as stressed
        print("--- PREDICTION: \(predicted_state)")
        if(predicted_state){
            if(loaded){
                stressStateLabel.text = "Stressed"
                getRecommendation()
            }
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "stressed"), object: nil)
        } else {
            if(loaded){
                stressStateLabel.text = "Not Stressed"
            }
        }
    }
    
    func stressNotification(_ activity: String){
        let content = UNMutableNotificationContent()
        content.title = "You Seem Stressed..."
        content.body = "Why don't you try \(activity)"
        content.categoryIdentifier = "stressDetection"
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        
        let request = UNNotificationRequest(identifier: "stressDetect", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    func resetStateFlag(){
        readyToPredict = true
    }

    /*
     *  Mark - helper functions
     */
    
    // Currently not used
    func writeFile(){
        print("--- WRITING TO FILE")
        let file = "data.csv" //this is the file. we will write to and read from it
        
        //var text = hrData.getCSVHeader()
        var text:String = ""
        for data in dataBuffer{
            text += data.getCSVFormat()
            print("\(data.getCSVFormat())")
        }
        
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            
            let path = dir.appendingPathComponent(file)
            
            //writing
            do {
                try text.write(to: path, atomically: false, encoding: String.Encoding.utf8)
            }
            catch {
                print("Error writing to file %s\n", file)
            }
        }
    }
    
    // source: http://stackoverflow.com/a/24098149
    func loadFile(){
        print("--- LOADING DATA")
        guard let csvPath = Bundle.main.path(forResource: "data", ofType: "csv") else {
            print("--- CSV NOT FOUND")
            return
        }
        
        do {
            let csvData = try String(contentsOfFile: csvPath, encoding: String.Encoding.utf8)
            let array = csvData.components(separatedBy: "\n")
            
            for item in array{
                let sub_array = item.components(separatedBy: ",")
                if(sub_array.count == 3){
                    self.dataBuffer.append(
                        hrData(time: NSDate().timeIntervalSince1970,
                               label: (sub_array[0] as NSString).integerValue,
                               hr: (sub_array[1] as NSString).doubleValue,
                               hrv: (sub_array[2] as NSString).doubleValue
                                )
                    )
                }
            }
        }catch{
            print(error)
        }
    }
    
    // Resize image helper function
    // Source: http://stackoverflow.com/a/31314494
    func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
        let size = image.size
        
        let widthRatio  = targetSize.width  / image.size.width
        let heightRatio = targetSize.height / image.size.height
        
        // Figure out what our orientation is, and use that to form the rectangle
        var newSize: CGSize
        if(widthRatio > heightRatio) {
            newSize = CGSize(width: size.width * heightRatio, height: size.height * heightRatio)
        } else {
            newSize = CGSize(width: size.width * widthRatio, height: size.height * widthRatio)
        }
        
        // This is the rect that we've calculated out and this is what is actually used below
        let rect = CGRect(x:0,y:0,width:newSize.width,height:newSize.height)
        
        // Actually do the resizing to the rect using the ImageContext stuff
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: rect)
        let newImage:UIImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        
        return newImage
    }
    
    
    
    func getRecommendation() {
        var activity : String = " "
        let id = UserDefaults.standard.object(forKey: "userID")!
        
        let userURL: String = "http://hoteiapi20170303100733.azurewebsites.net/GetUserRecommendation?userID=\(id)&numRec=1"
        
        var urlRequest = URLRequest(url: URL(string: userURL)!)
        
        var responses = [String]()
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")  // the request is JSON
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        
        let task = URLSession.shared.dataTask(with: urlRequest){ (data, response, error) in
            if error != nil{
                print(error!)
                return
            }
            
            do{
                let json = try JSONSerialization.jsonObject(with: data!) as! [String]
                responses = json
                
                if(responses.isEmpty){
                    
                    activity = " "
                }
                else{
                    activity = responses[0]
                    self.stressNotification(activity)
                }
            }
            catch let error{
                print(error)
            }
        }
        
        
        task.resume()
        print("notification")
        //self.stressNotification(activity)
        
    }
}


extension DataGatheringViewController: UNUserNotificationCenterDelegate{
//    	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
//    		completionHandler([.alert, .sound])
//    	}
}

